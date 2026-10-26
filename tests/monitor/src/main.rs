mod app;
mod model;
mod parse;
mod ui;

use std::io::stdout;
use std::path::PathBuf;
use std::time::Duration;

use ratatui::backend::{Backend, CrosstermBackend, TestBackend};
use ratatui::crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseButton, MouseEventKind,
};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::Terminal;

use app::App;

fn default_log_root() -> PathBuf {
    let temp = std::env::var("TEMP").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(temp).join("psmux-test-logs")
}

struct Args {
    snapshot: bool,
    run_dir: Option<PathBuf>,
}

fn parse_args() -> Args {
    let mut snapshot = false;
    let mut run_dir = None;
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--snapshot" => snapshot = true,
            "--run-dir" => run_dir = it.next().map(PathBuf::from),
            _ => {}
        }
    }
    Args { snapshot, run_dir }
}

fn main() {
    let args = parse_args();
    let root = default_log_root();
    let mut app = App::new(root, args.run_dir);

    if args.snapshot {
        run_snapshot(&mut app);
        return;
    }

    if let Err(err) = run_tui(&mut app) {
        // Terminal is already restored by the panic/exit paths below; just
        // report the error plainly.
        eprintln!("psmux-test-monitor error: {err}");
        std::process::exit(1);
    }
}

/// Render exactly one frame to a headless TestBackend and print it as plain
/// text, for automation to verify rendering without a real terminal.
fn run_snapshot(app: &mut App) {
    // Give the poller a couple of ticks so a freshly-started run has time to
    // pick up its run dir and first log lines.
    for _ in 0..2 {
        app.tick();
    }
    let backend = TestBackend::new(120, 40);
    let mut terminal = Terminal::new(backend).expect("failed to create test backend");
    terminal.draw(|f| ui::draw(f, app)).expect("failed to draw snapshot frame");
    print_buffer(terminal.backend());
    std::process::exit(0);
}

fn print_buffer(backend: &TestBackend) {
    let buffer = backend.buffer();
    let area = buffer.area;
    for y in 0..area.height {
        let mut line = String::with_capacity(area.width as usize);
        for x in 0..area.width {
            line.push_str(buffer[(x, y)].symbol());
        }
        println!("{}", line.trim_end());
    }
}

fn run_tui(app: &mut App) -> std::io::Result<()> {
    install_panic_hook();

    enable_raw_mode()?;
    let mut out = stdout();
    execute!(out, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(out);
    let mut terminal = Terminal::new(backend)?;

    let result = event_loop(&mut terminal, app);

    restore_terminal();
    result
}

fn install_panic_hook() {
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore_terminal();
        default_hook(info);
    }));
}

fn restore_terminal() {
    let _ = disable_raw_mode();
    let _ = execute!(stdout(), LeaveAlternateScreen, DisableMouseCapture);
}

// ratatui 0.30 turned `Backend::Error` into an associated type rather than
// always being `std::io::Error`, so `?` on `draw` needs the conversion spelled
// out. The only caller passes a `CrosstermBackend`, whose error already is
// `std::io::Error`.
fn event_loop<B: Backend>(terminal: &mut Terminal<B>, app: &mut App) -> std::io::Result<()>
where
    std::io::Error: From<<B as Backend>::Error>,
{
    loop {
        terminal.draw(|f| ui::draw(f, app))?;

        if event::poll(Duration::from_millis(250))? {
            match event::read()? {
                Event::Key(key) if key.kind == KeyEventKind::Press => {
                    if !handle_key(app, key.code) {
                        break;
                    }
                }
                Event::Mouse(mouse) => handle_mouse(app, mouse),
                Event::Resize(_, _) => {}
                _ => {}
            }
        }

        app.tick();
        if app.should_quit {
            break;
        }
    }
    Ok(())
}

/// Returns false if the app should quit.
fn handle_key(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::Char('q') | KeyCode::Esc => return false,
        KeyCode::Down | KeyCode::Char('j') => app.select_next(),
        KeyCode::Up | KeyCode::Char('k') => app.select_prev(),
        KeyCode::PageDown => app.page(1, 10),
        KeyCode::PageUp => app.page(-1, 10),
        KeyCode::Home => app.select_home(),
        KeyCode::End => app.select_end(),
        KeyCode::Char('f') => app.toggle_follow(),
        KeyCode::Char('1') => app.set_filter(model::FilterTab::All),
        KeyCode::Char('2') => app.set_filter(model::FilterTab::Running),
        KeyCode::Char('3') => app.set_filter(model::FilterTab::Fail),
        KeyCode::Char('4') => app.set_filter(model::FilterTab::Pass),
        KeyCode::Char('5') => app.set_filter(model::FilterTab::Skip),
        _ => {}
    }
    true
}

fn handle_mouse(app: &mut App, mouse: ratatui::crossterm::event::MouseEvent) {
    let (col, row) = (mouse.column, mouse.row);
    match mouse.kind {
        MouseEventKind::Down(MouseButton::Left) => {
            if let Some((_, tab)) = app.tab_rects.iter().find(|(r, _)| rect_contains(*r, col, row)) {
                app.set_filter(*tab);
                return;
            }
            if rect_contains(app.list_area, col, row) {
                // First row inside the list block is the top border.
                let content_y = app.list_area.y + 1;
                if row >= content_y {
                    let idx = app.list_scroll + (row - content_y) as usize;
                    let len = app.visible_names().len();
                    if idx < len {
                        app.selected = idx;
                    }
                }
                return;
            }
            if rect_contains(app.detail_area, col, row) {
                app.follow = false;
            }
        }
        MouseEventKind::ScrollDown => {
            if rect_contains(app.list_area, col, row) {
                app.select_next();
            } else if rect_contains(app.detail_area, col, row) {
                app.scroll_detail(3);
            }
        }
        MouseEventKind::ScrollUp => {
            if rect_contains(app.list_area, col, row) {
                app.select_prev();
            } else if rect_contains(app.detail_area, col, row) {
                app.scroll_detail(-3);
            }
        }
        _ => {}
    }
}

fn rect_contains(rect: ratatui::layout::Rect, col: u16, row: u16) -> bool {
    col >= rect.x && col < rect.x + rect.width && row >= rect.y && row < rect.y + rect.height
}
