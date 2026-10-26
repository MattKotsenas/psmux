// Live-client style options must share one server-side render-state contract:
//   1. ClientRenderOptions emits status and pane-content style fields.
//   2. list_windows_json_with_tabs() must carry per-window bell/last/activity
//      flags so the client can pick the right style.

use super::*;

#[derive(serde::Deserialize)]
struct LegacyClientRenderOptions {
    wsa_style: Option<String>,
    wsb_style: Option<String>,
    wsl_style: Option<String>,
    pane_border_indicators: Option<String>,
}

fn mk_app() -> AppState {
    let mut app = AppState::new("live_client_styles".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn mk_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: crate::types::LayoutKind::Horizontal, sizes: vec![], children: vec![] },
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

fn append_client_render_options(buf: &mut String, app: &AppState) -> std::io::Result<()> {
    let formats = expand_status_formats(app, "");
    append_client_render_options_json(buf, &formats.client_render_options)
}

// ── 1. The render-state JSON carries shared client-render options ──
#[test]
fn client_render_options_emit_status_and_window_flag_styles() {
    let mut app = mk_app();
    app.status_left_style = "fg=colour201".to_string();
    app.status_right_style = "bg=colour21".to_string();
    app.window_status_activity_style = "reverse".to_string();
    app.window_status_bell_style = "bg=blue".to_string();
    app.window_status_last_style = "fg=green".to_string();

    let mut buf = String::from("{\"status_style\":\"x\"}");
    append_client_render_options(&mut buf, &app).unwrap();

    let parsed: crate::render_state::ClientRenderOptions =
        serde_json::from_str(&buf).expect("typed client render options");
    assert_eq!(parsed.status_left_style.as_deref(), Some("fg=colour201"));
    assert_eq!(parsed.status_right_style.as_deref(), Some("bg=colour21"));
    assert_eq!(
        parsed.window_status_activity_style.as_deref(),
        Some("reverse"),
    );
    assert_eq!(
        parsed.window_status_bell_style.as_deref(),
        Some("bg=blue"),
    );
    assert_eq!(
        parsed.window_status_last_style.as_deref(),
        Some("fg=green"),
    );
    let legacy: LegacyClientRenderOptions =
        serde_json::from_str(&buf).expect("legacy wire options");
    assert_eq!(legacy.wsa_style.as_deref(), Some("reverse"));
    assert_eq!(legacy.wsb_style.as_deref(), Some("bg=blue"));
    assert_eq!(legacy.wsl_style.as_deref(), Some("fg=green"));
}

#[test]
fn client_render_options_emit_global_window_content_styles() {
    let mut app = mk_app();
    app.user_options.insert(
        "window-style".to_string(),
        "fg=colour245,bg=colour236".to_string(),
    );
    app.user_options.insert(
        "window-active-style".to_string(),
        "fg=colour250,bg=black".to_string(),
    );

    let mut buf = String::from("{\"layout\":{}}");
    append_client_render_options(&mut buf, &app).unwrap();

    let parsed: crate::render_state::ClientRenderOptions =
        serde_json::from_str(&buf).expect("typed client render options");
    assert_eq!(
        parsed.window_style.as_deref(),
        Some("fg=colour245,bg=colour236"),
    );
    assert_eq!(
        parsed.window_active_style.as_deref(),
        Some("fg=colour250,bg=black"),
    );
}

#[test]
fn client_render_options_emit_empty_global_window_content_styles_when_unset() {
    let app = mk_app();
    let mut buf = String::from("{\"layout\":{}}");
    append_client_render_options(&mut buf, &app).unwrap();

    let parsed: crate::render_state::ClientRenderOptions =
        serde_json::from_str(&buf).expect("typed client render options");
    assert_eq!(parsed.window_style.as_deref(), Some(""));
    assert_eq!(parsed.window_active_style.as_deref(), Some(""));
}

#[test]
fn client_render_options_emit_pane_border_indicators_and_default() {
    let mut app = mk_app();
    let mut default_buf = String::from("{\"layout\":{}}");
    append_client_render_options(&mut default_buf, &app).unwrap();
    let default_options: crate::render_state::ClientRenderOptions =
        serde_json::from_str(&default_buf).expect("typed default options");
    assert_eq!(
        default_options.pane_border_indicators,
        Some(crate::pane_border::PaneBorderIndicators::Colour),
    );
    let default_legacy: LegacyClientRenderOptions =
        serde_json::from_str(&default_buf).expect("legacy default options");
    assert_eq!(
        default_legacy.pane_border_indicators.as_deref(),
        Some("colour"),
    );

    app.user_options.insert(
        "pane-border-indicators".to_string(),
        "arrows".to_string(),
    );
    let mut arrows_buf = String::from("{\"layout\":{}}");
    append_client_render_options(&mut arrows_buf, &app).unwrap();
    let arrows_options: crate::render_state::ClientRenderOptions =
        serde_json::from_str(&arrows_buf).expect("typed arrows options");
    assert_eq!(
        arrows_options.pane_border_indicators,
        Some(crate::pane_border::PaneBorderIndicators::Arrows),
    );
    let arrows_legacy: LegacyClientRenderOptions =
        serde_json::from_str(&arrows_buf).expect("legacy arrows options");
    assert_eq!(
        arrows_legacy.pane_border_indicators.as_deref(),
        Some("arrows"),
    );
}

#[test]
fn client_render_options_reject_missing_object_delimiter() {
    let app = mk_app();
    let mut buf = String::from("[1,2,3]");
    assert!(append_client_render_options(&mut buf, &app).is_err());
    assert_eq!(buf, "[1,2,3]", "must not corrupt a non-object buffer");
}

// ── 2. Per-window flags must be plumbed so the client can style tabs ──
#[test]
fn list_windows_json_carries_bell_activity_last_flags() {
    let mut app = mk_app();
    app.windows.push(mk_window("w0", 0));
    app.windows.push(mk_window("w1", 1));
    app.active_idx = 1;        // w1 is current
    app.last_window_idx = 0;   // w0 is the last-active window
    app.windows[0].activity_flag = true;
    app.windows[0].bell_flag = true;

    let json = crate::server::helpers::list_windows_json_with_tabs(&app).unwrap();
    let arr: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
    assert_eq!(arr.len(), 2);

    // w0: not active, but bell + activity + last flags all set.
    assert_eq!(arr[0]["active"], false);
    assert_eq!(arr[0]["bell"], true, "bell flag not plumbed: {json}");
    assert_eq!(arr[0]["activity"], true, "activity flag not plumbed: {json}");
    assert_eq!(arr[0]["last"], true, "last flag not plumbed: {json}");

    // w1: active, and definitely not the last window.
    assert_eq!(arr[1]["active"], true);
    assert_eq!(arr[1]["last"], false);
    assert_eq!(arr[1]["bell"], false);
}
