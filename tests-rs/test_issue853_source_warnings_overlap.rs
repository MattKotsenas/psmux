// Issue #853: two runtime sources that overlap kept only the warnings of the
// one that finished last. The server holds one list of config warnings
// (written to config-warnings.log, shown on the status line, and the
// __config-warnings reply); every runtime source started it over, and a source
// job replaced it with its own when it finished, so a source that finished
// while the job ran lost its warnings from the list. Each client still heard
// of its own.
//
// tmux keeps one list too (cfg.c:31, cfg_causes) and adds to it
// (cfg_add_cause); a source-file prints what is there when it completes and
// empties it (cmd-source-file.c:76, cfg_print_causes). Nothing replaces it.
//
// These tests pin the list across sources that overlap. The routes end to
// end are in tests/test_issue853_source_warnings_overlap.ps1.

use super::*;

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: crate::types::Node::Split {
            kind: crate::types::LayoutKind::Horizontal,
            sizes: vec![],
            children: vec![],
        },
        active_path: vec![],
        name: name.to_string(),
        id,
        area: ratatui::layout::Rect::new(0, 0, 120, 30),
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    }
}

/// A server with one window, as a runtime source-file finds it.
fn app_with_window() -> AppState {
    let mut app = AppState::new("swo".to_string());
    app.windows.push(make_window("shell", 0));
    app
}

/// A file of its own for each test, removed when the guard drops.
struct TempConf(std::path::PathBuf);
impl TempConf {
    fn new(tag: &str, content: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "psmux_test_swo_{}_{}_{}.conf",
            std::process::id(),
            tag,
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::write(&path, content).unwrap();
        TempConf(path)
    }
    fn path(&self) -> String {
        self.0.display().to_string()
    }
}
impl Drop for TempConf {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn names(list: &[String]) -> Vec<&str> {
    // The option each warning is about, which is all these tests compare.
    list.iter()
        .map(|w| ["no-such-a1", "no-such-a2", "no-such-b", "no-such-c"].into_iter().find(|n| w.contains(n)).unwrap_or("?"))
        .collect()
}

/// Source A has a job: a bad option before its first command (a parse
/// warning) and one after it (the job's own, reported when it finishes).
fn start_source_a(app: &mut AppState, a: &TempConf) -> crate::types::SourceParse {
    let parsed = source_runtime(app, &a.path());
    assert!(!parsed.lines.is_empty(), "A has a job");
    // What the server loop does when it starts the job.
    app.source_jobs_running += 1;
    parsed
}

fn file_a() -> TempConf {
    TempConf::new("a", "set -g no-such-a1 on\ndisplay-message -p x\nset -g no-such-a2 on\n")
}

fn file_b() -> TempConf {
    TempConf::new("b", "set -g no-such-b on\n")
}

#[test]
fn a_source_that_runs_while_a_job_does_adds_to_the_list() {
    let (a, b) = (file_a(), file_b());
    let mut app = app_with_window();
    start_source_a(&mut app, &a);
    let parsed_b = source_runtime(&mut app, &b.path());
    assert!(parsed_b.lines.is_empty(), "B has no job");
    assert_eq!(names(&app.config_warnings), ["no-such-a1", "no-such-b"]);
}

#[test]
fn each_source_reports_only_its_own_warnings_to_its_client() {
    let (a, b) = (file_a(), file_b());
    let mut app = app_with_window();
    let parsed_a = start_source_a(&mut app, &a);
    assert_eq!(names(&parsed_a.errors), ["no-such-a1"]);
    let parsed_b = source_runtime(&mut app, &b.path());
    assert_eq!(names(&parsed_b.errors), ["no-such-b"], "not A's, though they are in the list");
}

#[test]
fn a_job_that_finishes_adds_its_own_and_keeps_the_others() {
    let (a, b) = (file_a(), file_b());
    let mut app = app_with_window();
    let parsed_a = start_source_a(&mut app, &a);
    source_runtime(&mut app, &b.path());
    // The job's report: the parse's warning, then the one its replay found.
    let mut warnings = parsed_a.errors.clone();
    let new_from = warnings.len();
    warnings.push(format!("{}:3: unknown option: no-such-a2", a.path()));
    finish_source_job_warnings(&mut app, &warnings, new_from);
    assert_eq!(names(&app.config_warnings), ["no-such-a1", "no-such-b", "no-such-a2"]);
    assert_eq!(app.source_jobs_running, 0);
}

#[test]
fn the_status_line_shows_the_finishing_sources_own_warnings() {
    let (a, b) = (file_a(), file_b());
    let mut app = app_with_window();
    let parsed_a = start_source_a(&mut app, &a);
    source_runtime(&mut app, &b.path());
    let mut warnings = parsed_a.errors.clone();
    let new_from = warnings.len();
    warnings.push(format!("{}:3: unknown option: no-such-a2", a.path()));
    finish_source_job_warnings(&mut app, &warnings, new_from);
    let (msg, _, _) = app.status_message.clone().expect("a status message");
    assert!(msg.starts_with("2 config warnings"), "A's two, not the list's three: {}", msg);
    assert!(msg.contains("no-such-a1"), "{}", msg);
}

#[test]
fn with_no_job_running_a_new_source_starts_the_list_over() {
    let (a, b) = (file_a(), file_b());
    let c = TempConf::new("c", "set -g no-such-c on\n");
    let mut app = app_with_window();
    let parsed_a = start_source_a(&mut app, &a);
    source_runtime(&mut app, &b.path());
    finish_source_job_warnings(&mut app, &parsed_a.errors, parsed_a.errors.len());
    source_runtime(&mut app, &c.path());
    assert_eq!(names(&app.config_warnings), ["no-such-c"]);
}

#[test]
fn a_cycle_refused_while_a_job_runs_keeps_the_jobs_warnings() {
    let a = file_a();
    let cyc = TempConf::new("cyc", "");
    std::fs::write(&cyc.0, format!("source-file {}\n", crate::util::quote_arg(&cyc.path()))).unwrap();
    let mut app = app_with_window();
    start_source_a(&mut app, &a);
    let parsed = source_runtime(&mut app, &cyc.path());
    assert_eq!(parsed.errors.len(), 1);
    assert_eq!(app.config_warnings.len(), 2, "A's warning and the cycle: {:?}", app.config_warnings);
    assert!(app.config_warnings[0].contains("no-such-a1"));
}

#[test]
fn the_job_count_never_goes_below_zero() {
    let mut app = app_with_window();
    finish_source_job_warnings(&mut app, &[], 0);
    assert_eq!(app.source_jobs_running, 0);
}
