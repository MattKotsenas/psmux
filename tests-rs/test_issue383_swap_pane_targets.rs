use super::*;

fn make_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: name.to_string(),
        id,
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
    }
}

#[test]
fn swap_pane_target_below_pane_base_index_is_invalid() {
    let mut app = AppState::new("issue383".to_string());
    app.pane_base_index = 1;
    app.windows.push(make_window("w0", 0));
    app.active_idx = 0;

    // Regression guard: `.0` must not saturate to pane 0 when pane-base-index=1.
    let path = resolve_swap_pane_target_path(&app, ".0");
    assert!(path.is_none(), "target below pane-base-index should be rejected");
}
