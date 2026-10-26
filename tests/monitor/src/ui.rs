// Rendering: turns an &mut App into a ratatui frame. Also records hit-test
// rectangles (header tabs, list area, detail area) back onto App so the
// event loop can resolve mouse clicks/scrolls against the layout that was
// actually drawn this frame.

use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Bar, BarChart, BarGroup, Block, BorderType, Borders, Gauge, List, ListItem, Paragraph};
use ratatui::Frame;

use crate::app::App;
use crate::model::{FilterTab, Status};

const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

fn status_style(status: Status) -> Style {
    match status {
        Status::Queued => Style::default().fg(Color::DarkGray),
        Status::Running => Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        Status::Pass => Style::default().fg(Color::Green),
        Status::Fail => Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        Status::Timeout => Style::default().fg(Color::Magenta).add_modifier(Modifier::BOLD),
        Status::Skip => Style::default().fg(Color::Yellow),
        Status::Error => Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
    }
}

/// Static status glyph. Running is special-cased at the call site (it uses
/// the current braille spinner frame instead of a fixed glyph).
fn status_glyph(status: Status) -> &'static str {
    match status {
        Status::Queued => "·",
        Status::Running => "@",
        Status::Pass => "✓",
        Status::Fail => "✗",
        Status::Timeout => "⏳",
        Status::Skip => "-",
        Status::Error => "✗",
    }
}

fn fmt_hms(total_secs: u64) -> String {
    let h = total_secs / 3600;
    let m = (total_secs % 3600) / 60;
    let s = total_secs % 60;
    if h > 0 {
        format!("{h}h{m:02}m{s:02}s")
    } else if m > 0 {
        format!("{m}m{s:02}s")
    } else {
        format!("{s}s")
    }
}

fn fmt_eta(secs: f64) -> String {
    if !secs.is_finite() || secs <= 0.0 {
        return "--".to_string();
    }
    fmt_hms(secs.round() as u64)
}

pub fn draw(f: &mut Frame, app: &mut App) {
    let size = f.area();
    let root = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(5),
            Constraint::Min(8),
            Constraint::Length(9),
            Constraint::Length(1),
        ])
        .split(size);

    draw_header(f, app, root[0]);
    draw_body(f, app, root[1]);
    draw_metrics(f, app, root[2]);
    draw_help(f, app, root[3]);
}

fn draw_header(f: &mut Frame, app: &mut App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(Span::styled(
            " psmux test monitor ",
            Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(area);
    f.render_widget(block, area);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Length(1), Constraint::Length(1)])
        .split(inner);

    let stats = app.run.stats();
    let elapsed = fmt_hms(app.start.elapsed().as_secs());
    let eta = match stats.avg_duration {
        Some(avg) => fmt_eta(crate::parse::eta_seconds(stats.done, stats.total, avg)),
        None => "--".to_string(),
    };
    let run_id = if app.run.run_id.is_empty() { "(waiting for run...)" } else { &app.run.run_id };
    let title_line = Line::from(vec![
        Span::styled("Run: ", Style::default().fg(Color::DarkGray)),
        Span::styled(run_id.to_string(), Style::default().fg(Color::White).add_modifier(Modifier::BOLD)),
        Span::raw("   "),
        Span::styled("Elapsed: ", Style::default().fg(Color::DarkGray)),
        Span::styled(elapsed, Style::default().fg(Color::White)),
        Span::raw("   "),
        Span::styled("ETA: ", Style::default().fg(Color::DarkGray)),
        Span::styled(eta, Style::default().fg(Color::Cyan)),
    ]);
    f.render_widget(Paragraph::new(title_line), rows[0]);

    let pct = if stats.total > 0 { (stats.done as f64 / stats.total as f64 * 100.0) as u16 } else { 0 };
    let gauge_color = if stats.fail + stats.timeout + stats.error > 0 { Color::Red } else { Color::Green };
    let gauge = Gauge::default()
        .gauge_style(Style::default().fg(gauge_color).bg(Color::Black))
        .ratio((pct as f64 / 100.0).clamp(0.0, 1.0))
        .label(format!("{}/{} suites ({pct}%)", stats.done, stats.total));
    f.render_widget(gauge, rows[1]);

    draw_tabs(f, app, rows[2]);
}

fn draw_tabs(f: &mut Frame, app: &mut App, area: Rect) {
    app.tab_rects.clear();
    let mut x = area.x;
    let mut spans = Vec::new();
    for tab in FilterTab::ALL {
        let label = format!(" {} ", tab.label());
        let width = label.chars().count() as u16;
        let style = if tab == app.filter {
            Style::default().fg(Color::Black).bg(Color::Cyan).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(Color::Gray)
        };
        spans.push(Span::styled(label.clone(), style));
        let rect = Rect { x, y: area.y, width, height: 1.min(area.height) };
        app.tab_rects.push((rect, tab));
        x = x.saturating_add(width);
        if x >= area.x + area.width {
            break;
        }
    }
    f.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn draw_body(f: &mut Frame, app: &mut App, area: Rect) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
        .split(area);
    draw_list(f, app, cols[0]);
    draw_detail(f, app, cols[1]);
}

fn draw_list(f: &mut Frame, app: &mut App, area: Rect) {
    app.list_area = area;
    let names = app.visible_names();
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(format!(" Suites ({}/{}) ", names.len(), app.run.stats().total));

    let spinner = SPINNER[(app.tick_count as usize) % SPINNER.len()];
    let items: Vec<ListItem> = names
        .iter()
        .map(|name| {
            let suite = app.run.suites.get(name);
            let status = suite.map(|s| s.status).unwrap_or(Status::Queued);
            let glyph = if status == Status::Running { spinner } else { status_glyph(status) };
            let mut spans = vec![
                Span::styled(format!("{glyph} "), status_style(status)),
                Span::styled(format!("{name:<40}"), status_style(status)),
            ];
            match status {
                Status::Running => {
                    if let Some((elapsed, limit)) = suite.and_then(|s| s.heartbeat) {
                        spans.push(Span::styled(
                            format!(" {elapsed:.0}s/{limit:.0}s"),
                            Style::default().fg(Color::Cyan),
                        ));
                    }
                }
                Status::Pass | Status::Fail => {
                    if let Some(s) = suite {
                        spans.push(Span::styled(
                            format!(" {}P/{}F", s.passed, s.failed),
                            Style::default().fg(Color::DarkGray),
                        ));
                    }
                }
                Status::Timeout => spans.push(Span::styled(" TIMEOUT", Style::default().fg(Color::Magenta))),
                Status::Skip => {
                    if let Some(reason) = suite.and_then(|s| s.reason.as_deref()) {
                        spans.push(Span::styled(format!(" ({reason})"), Style::default().fg(Color::DarkGray)));
                    }
                }
                _ => {}
            }
            ListItem::new(Line::from(spans))
        })
        .collect();

    app.list_state.select(if names.is_empty() { None } else { Some(app.selected) });

    let list = List::new(items)
        .block(block)
        .highlight_style(Style::default().add_modifier(Modifier::REVERSED).add_modifier(Modifier::BOLD));
    f.render_stateful_widget(list, area, &mut app.list_state);
    app.list_scroll = app.list_state.offset();
}

fn draw_detail(f: &mut Frame, app: &mut App, area: Rect) {
    app.detail_area = area;
    let names = app.visible_names();
    let selected_name = names.get(app.selected).cloned();
    let suite = selected_name.as_ref().and_then(|n| app.run.suites.get(n));

    let live_badge = if app.detail_is_live { " [LIVE]" } else { "" };
    let follow_badge = if app.follow && app.detail_is_live { " [following]" } else if !app.follow { " [manual scroll]" } else { "" };
    let title = match &selected_name {
        Some(n) => format!(" {n}{live_badge}{follow_badge} "),
        None => " (no suite selected) ".to_string(),
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(title);
    let inner = block.inner(area);
    f.render_widget(block, area);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0)])
        .split(inner);

    let summary = match suite {
        Some(s) => {
            let status = s.status;
            let mut parts = vec![Span::styled(format!("{} ", status.label()), status_style(status))];
            if let Some(d) = s.duration {
                parts.push(Span::styled(format!("dur={d:.1}s  "), Style::default().fg(Color::DarkGray)));
            }
            if let Some(e) = s.exit_code {
                parts.push(Span::styled(format!("exit={e}  "), Style::default().fg(Color::DarkGray)));
            }
            parts.push(Span::styled(format!("{}P/{}F", s.passed, s.failed), Style::default().fg(Color::DarkGray)));
            Line::from(parts)
        }
        None => Line::from(""),
    };
    f.render_widget(Paragraph::new(summary), rows[0]);

    let text: Vec<Line> = app
        .detail_lines
        .iter()
        .map(|l| Line::from(Span::raw(l.clone())))
        .collect();
    let scroll = app.detail_scroll.min(app.detail_lines.len()) as u16;
    let para = Paragraph::new(text).scroll((scroll, 0));
    f.render_widget(para, rows[1]);
}

fn draw_metrics(f: &mut Frame, app: &mut App, area: Rect) {
    let stats = app.run.stats();
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(4), Constraint::Min(5)])
        .split(area);

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(34), Constraint::Percentage(33), Constraint::Percentage(33)])
        .split(rows[0]);

    let pass_rate = stats.pass_rate();
    let gauge_color = if pass_rate >= 0.9 {
        Color::Green
    } else if pass_rate >= 0.6 {
        Color::Yellow
    } else {
        Color::Red
    };
    let gauge = Gauge::default()
        .block(Block::default().borders(Borders::ALL).border_type(BorderType::Rounded).title(" Pass rate "))
        .gauge_style(Style::default().fg(gauge_color))
        .ratio(pass_rate.clamp(0.0, 1.0))
        .label(format!("{:.1}%", pass_rate * 100.0));
    f.render_widget(gauge, cols[0]);

    let counts = Paragraph::new(vec![
        Line::from(vec![
            Span::styled(format!("PASS {} ", stats.pass), Style::default().fg(Color::Green)),
            Span::styled(format!("FAIL {} ", stats.fail), Style::default().fg(Color::Red)),
            Span::styled(format!("TIMEOUT {} ", stats.timeout), Style::default().fg(Color::Magenta)),
        ]),
        Line::from(vec![
            Span::styled(format!("SKIP {} ", stats.skip), Style::default().fg(Color::Yellow)),
            Span::styled(format!("ERROR {} ", stats.error), Style::default().fg(Color::Red)),
            Span::styled(format!("tests {}P/{}F", stats.tests_passed, stats.tests_failed), Style::default().fg(Color::DarkGray)),
        ]),
    ])
    .block(Block::default().borders(Borders::ALL).border_type(BorderType::Rounded).title(" Counters "));
    f.render_widget(counts, cols[1]);

    let avg_p90 = Paragraph::new(vec![
        Line::from(Span::styled(
            format!("avg: {}", stats.avg_duration.map(|v| format!("{v:.1}s")).unwrap_or_else(|| "--".into())),
            Style::default().fg(Color::White),
        )),
        Line::from(Span::styled(
            format!("p90: {}", stats.p90_duration.map(|v| format!("{v:.1}s")).unwrap_or_else(|| "--".into())),
            Style::default().fg(Color::White),
        )),
    ])
    .block(Block::default().borders(Borders::ALL).border_type(BorderType::Rounded).title(" Duration "));
    f.render_widget(avg_p90, cols[2]);

    draw_slowest_barchart(f, &stats, rows[1]);
}

fn draw_slowest_barchart(f: &mut Frame, stats: &crate::model::Stats, area: Rect) {
    let bars: Vec<Bar> = stats
        .slowest
        .iter()
        .map(|(name, dur)| {
            let label = if name.len() > 10 { format!("{}..", &name[..10]) } else { name.clone() };
            Bar::default()
                .value((dur * 10.0).round() as u64)
                .label(Line::from(label))
                .text_value(format!("{dur:.1}s"))
                .style(Style::default().fg(Color::Cyan))
        })
        .collect();

    let chart = BarChart::default()
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .title(" Slowest 10 suites "),
        )
        .data(BarGroup::default().bars(&bars))
        .bar_width(9)
        .bar_gap(1)
        .value_style(Style::default().fg(Color::Black).bg(Color::Cyan));
    f.render_widget(chart, area);
}

fn draw_help(f: &mut Frame, app: &mut App, area: Rect) {
    let final_msg = app.run.final_result.as_deref();
    let text = if let Some(msg) = final_msg {
        format!(" {msg}  |  q: quit ")
    } else {
        " ↑/↓ j/k select  PgUp/PgDn/Home/End  mouse: click select/tab, wheel scroll  f: follow  q: quit ".to_string()
    };
    let style = if final_msg.is_some() {
        Style::default().fg(Color::Black).bg(Color::Green).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::DarkGray)
    };
    f.render_widget(Paragraph::new(text).style(style).alignment(Alignment::Left), area);
}
