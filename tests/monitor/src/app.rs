// Application state: polling the log files on disk and turning them into a
// RunSnapshot, plus UI-only state (selection, scroll, filter, follow mode).

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Instant;

use ratatui::layout::Rect;
use ratatui::widgets::ListState;

use crate::model::{FilterTab, RunSnapshot, Status};
use crate::parse::{parse_progress_line, parse_results_jsonl, ProgressEvent};

pub struct App {
    pub root: PathBuf,
    pub run_dir_override: Option<PathBuf>,
    pub run_dir: Option<PathBuf>,
    pub run: RunSnapshot,
    pub filter: FilterTab,
    pub selected: usize,
    pub detail_scroll: usize,
    pub follow: bool,
    pub start: Instant,
    pub last_run_check: Instant,

    progress_offset: u64,
    results_offset: u64,

    pub detail_lines: Vec<String>,
    pub detail_is_live: bool,
    pub detail_suite: Option<String>,

    pub should_quit: bool,
    pub tick_count: u64,
    pub list_state: ListState,

    // Hit-test areas populated by the UI layer on each draw.
    pub tab_rects: Vec<(Rect, FilterTab)>,
    pub list_area: Rect,
    pub detail_area: Rect,
    pub list_scroll: usize,
}

impl App {
    pub fn new(root: PathBuf, run_dir_override: Option<PathBuf>) -> Self {
        App {
            root,
            run_dir_override,
            run_dir: None,
            run: RunSnapshot::default(),
            filter: FilterTab::All,
            selected: 0,
            detail_scroll: 0,
            follow: true,
            start: Instant::now(),
            last_run_check: Instant::now() - std::time::Duration::from_secs(60),
            progress_offset: 0,
            results_offset: 0,
            detail_lines: Vec::new(),
            detail_is_live: false,
            detail_suite: None,
            should_quit: false,
            tick_count: 0,
            list_state: ListState::default(),
            tab_rects: Vec::new(),
            list_area: Rect::default(),
            detail_area: Rect::default(),
            list_scroll: 0,
        }
    }

    /// Resolve which run directory we should be watching, hopping to a new
    /// run automatically when latest_run.txt changes (unless pinned via
    /// --run-dir).
    fn refresh_run_dir(&mut self) {
        if let Some(dir) = &self.run_dir_override {
            if self.run_dir.as_deref() != Some(dir.as_path()) {
                self.switch_run(dir.clone());
            }
            return;
        }
        let latest = self.root.join("latest_run.txt");
        let Ok(text) = std::fs::read_to_string(&latest) else { return };
        let run_id = text.trim().trim_matches(|c| c == '\r' || c == '\n');
        if run_id.is_empty() {
            return;
        }
        let dir = self.root.join(run_id);
        if self.run_dir.as_deref() != Some(dir.as_path()) {
            self.switch_run(dir);
        }
    }

    fn switch_run(&mut self, dir: PathBuf) {
        let run_id = dir
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        self.run = RunSnapshot::new(run_id);
        self.run_dir = Some(dir);
        self.progress_offset = 0;
        self.results_offset = 0;
        self.selected = 0;
        self.list_scroll = 0;
        self.detail_scroll = 0;
        self.follow = true;
        self.detail_lines.clear();
        self.detail_suite = None;
    }

    /// Called once per tick (~250ms). Cheap: only re-checks latest_run.txt
    /// occasionally, but always polls the append-only logs for the active run.
    pub fn tick(&mut self) {
        self.tick_count = self.tick_count.wrapping_add(1);
        if self.run_dir_override.is_none() && self.last_run_check.elapsed().as_secs() >= 3 {
            self.last_run_check = Instant::now();
            self.refresh_run_dir();
        }
        if self.run_dir.is_none() {
            self.refresh_run_dir();
        }
        let Some(dir) = self.run_dir.clone() else { return };
        self.poll_progress(&dir);
        self.poll_results(&dir);
        self.refresh_detail(&dir);
    }

    fn poll_progress(&mut self, dir: &Path) {
        let path = dir.join("progress.log");
        let Some(chunk) = read_new_complete_lines(&path, &mut self.progress_offset) else { return };
        for line in chunk.lines() {
            if let Some(ev) = parse_progress_line(line) {
                self.apply_event(ev);
            }
        }
    }

    fn apply_event(&mut self, ev: ProgressEvent) {
        match ev {
            ProgressEvent::Queuing { n, total, name } => self.run.on_queue(n, total, &name),
            ProgressEvent::Start { name } => self.run.on_start(&name),
            ProgressEvent::Heartbeat { name, elapsed, limit } => {
                self.run.on_heartbeat(&name, elapsed, limit)
            }
            ProgressEvent::Result { status, name, passed, failed, exit_code, duration } => {
                if let Some(status) = Status::from_str(&status) {
                    self.run.on_result_line(status, &name, passed, failed, exit_code, duration);
                }
            }
            ProgressEvent::TimeoutEarly { name } => {
                self.run.on_heartbeat(&name, 0.0, 0.0);
                if let Some(s) = self.run.suites.get_mut(&name) {
                    s.status = Status::Timeout;
                }
            }
            ProgressEvent::Skip { name, reason } => self.run.on_skip(&name, &reason),
            ProgressEvent::Error { name, message } => self.run.on_error_line(&name, &message),
            ProgressEvent::FinalResult { message } => self.run.final_result = Some(message),
        }
    }

    fn poll_results(&mut self, dir: &Path) {
        let path = dir.join("results.jsonl");
        let Some(chunk) = read_new_complete_lines(&path, &mut self.results_offset) else { return };
        for rec in parse_results_jsonl(&chunk) {
            self.run.on_result_record(&rec);
        }
    }

    fn refresh_detail(&mut self, dir: &Path) {
        let names = self.run.filtered_order(self.filter);
        if names.is_empty() {
            self.detail_lines.clear();
            self.detail_suite = None;
            self.detail_is_live = false;
            return;
        }
        if self.selected >= names.len() {
            self.selected = names.len() - 1;
        }
        let name = names[self.selected].to_string();
        let is_running = self
            .run
            .suites
            .get(&name)
            .map(|s| s.status == Status::Running)
            .unwrap_or(false);

        if is_running {
            let path = dir.join("suites").join(format!("{name}.out.tmp"));
            if let Ok(text) = std::fs::read_to_string(&path) {
                self.detail_lines = text.lines().map(|s| s.to_string()).collect();
            }
            self.detail_is_live = true;
            self.detail_suite = Some(name);
            if self.follow {
                self.detail_scroll = self.detail_lines.len();
            }
        } else if self.detail_suite.as_deref() != Some(name.as_str()) || self.detail_is_live {
            // (Re)load the static, completed log once per selection change.
            let path = dir.join("suites").join(format!("{name}.log"));
            self.detail_lines = std::fs::read_to_string(&path)
                .map(|t| t.lines().map(|s| s.to_string()).collect())
                .unwrap_or_default();
            self.detail_is_live = false;
            self.detail_suite = Some(name);
            self.detail_scroll = 0;
            self.follow = true;
        }
    }

    // --- Interaction -----------------------------------------------------

    pub fn visible_names(&self) -> Vec<String> {
        self.run
            .filtered_order(self.filter)
            .into_iter()
            .map(|s| s.to_string())
            .collect()
    }

    pub fn select_next(&mut self) {
        let len = self.visible_names().len();
        if len == 0 {
            return;
        }
        if self.selected + 1 < len {
            self.selected += 1;
        }
    }

    pub fn select_prev(&mut self) {
        if self.selected > 0 {
            self.selected -= 1;
        }
    }

    pub fn select_home(&mut self) {
        self.selected = 0;
    }

    pub fn select_end(&mut self) {
        let len = self.visible_names().len();
        self.selected = len.saturating_sub(1);
    }

    pub fn page(&mut self, delta: isize, page_size: usize) {
        let len = self.visible_names().len() as isize;
        if len == 0 {
            return;
        }
        let mut next = self.selected as isize + delta * page_size as isize;
        if next < 0 {
            next = 0;
        }
        if next >= len {
            next = len - 1;
        }
        self.selected = next as usize;
    }

    pub fn set_filter(&mut self, filter: FilterTab) {
        if self.filter != filter {
            self.filter = filter;
            self.selected = 0;
            self.list_scroll = 0;
        }
    }

    pub fn scroll_detail(&mut self, delta: isize) {
        self.follow = false;
        let len = self.detail_lines.len() as isize;
        let mut next = self.detail_scroll as isize + delta;
        if next < 0 {
            next = 0;
        }
        if next > len {
            next = len;
        }
        self.detail_scroll = next as usize;
    }

    pub fn toggle_follow(&mut self) {
        self.follow = !self.follow;
        if self.follow {
            self.detail_scroll = self.detail_lines.len();
        }
    }
}

/// Read any newly-appended, newline-terminated bytes from `path` since
/// `offset`, advancing `offset` only past complete lines. This tolerates a
/// concurrent writer mid-append (a trailing partial line is left for the
/// next poll) and tolerates transient read errors (file momentarily locked,
/// truncated/rotated, or not yet created) by simply reporting no new data
/// rather than panicking.
fn read_new_complete_lines(path: &Path, offset: &mut u64) -> Option<String> {
    let mut file = File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    if len < *offset {
        // File shrank/rotated underneath us: restart from the top.
        *offset = 0;
    }
    if len == *offset {
        return None;
    }
    file.seek(SeekFrom::Start(*offset)).ok()?;
    let mut buf = String::new();
    file.read_to_string(&mut buf).ok()?;
    if buf.is_empty() {
        return None;
    }
    match buf.rfind('\n') {
        Some(idx) => {
            *offset += (idx + 1) as u64;
            Some(buf[..=idx].to_string())
        }
        None => None, // no complete line yet
    }
}
