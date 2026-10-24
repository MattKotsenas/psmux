use super::*;
use crate::types::NO_LAST_WINDOW;

fn window(id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: format!("w{id}"),
        id,
        area: ratatui::layout::Rect::new(0, 0, 120, 30),
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
        floating: vec![],
        floating_focus: None,
    }
}

fn fixture() -> AppState {
    let mut app = AppState::new("unlink-focus".to_string());
    app.windows = [10, 20, 30, 40].into_iter().map(window).collect();
    app.window_indices = vec![2, 5, 8, 13];
    app.window_base_index = 2;
    app
}

#[test]
fn unlink_preserves_surviving_active_and_last_window_identities() {
    for renumber in [false, true] {
        for active in 0..4 {
            for removed in 0..4 {
                for last in [0, 1, 2, 3, NO_LAST_WINDOW] {
                    if last == active { continue; }
                    let mut app = fixture();
                    app.active_idx = active;
                    app.last_window_idx = last;
                    app.renumber_windows = renumber;
                    let ids: Vec<_> = app.windows.iter().map(|w| w.id).collect();
                    assert_eq!(ids, [10, 20, 30, 40]);
                    assert_eq!(app.window_indices, [2, 5, 8, 13]);
                    let removed_id = ids[removed];
                    let survivors: Vec<_> = ids.iter().copied().filter(|id| *id != removed_id).collect();
                    let expected_active = if removed == active {
                        // Keep the existing current-window policy: next slot, or previous at the tail.
                        survivors[active.min(survivors.len() - 1)]
                    } else {
                        ids[active]
                    };
                    let expected_last = ids.get(last).copied().filter(|id| *id != removed_id);
                    let case = format!("active={active}, removed={removed}, last={last}, renumber={renumber}");

                    execute_command_string(&mut app, &format!("unlink-window -t @{removed_id}")).unwrap();

                    assert_eq!(app.windows.iter().map(|w| w.id).collect::<Vec<_>>(), survivors, "{case}");
                    assert_eq!(app.windows[app.active_idx].id, expected_active, "{case}");
                    assert_eq!(app.windows.get(app.last_window_idx).map(|w| w.id), expected_last, "{case}");
                    if expected_last.is_none() {
                        assert_eq!(app.last_window_idx, NO_LAST_WINDOW, "{case}");
                        assert_eq!(app.last_window_pos(), None, "{case}");
                    }
                    let expected_indices = if renumber {
                        vec![2, 3, 4]
                    } else {
                        [2, 5, 8, 13].into_iter().enumerate()
                            .filter_map(|(pos, index)| (pos != removed).then_some(index)).collect()
                    };
                    assert_eq!(app.window_indices, expected_indices, "{case}");
                }
            }
        }
    }
}

#[test]
fn unlink_before_active_keeps_last_window_navigation() {
    let mut app = fixture();
    app.active_idx = 2;
    app.last_window_idx = 1;
    assert_eq!(app.windows[app.active_idx].id, 30);
    assert_eq!(app.windows[app.last_window_idx].id, 20);

    execute_command_string(&mut app, "unlink-window -t :2").unwrap();
    assert_eq!(app.windows[app.active_idx].id, 30);
    execute_command_string(&mut app, "last-window").unwrap();
    assert_eq!(app.windows[app.active_idx].id, 20);
    execute_command_string(&mut app, "last-window").unwrap();
    assert_eq!(app.windows[app.active_idx].id, 30);
}

#[test]
fn unlink_missing_target_and_only_window_leave_focus_unchanged() {
    let mut app = fixture();
    app.active_idx = 2;
    app.last_window_idx = 1;
    assert!(app.status_message.is_none());
    execute_command_string(&mut app, "unlink-window -t @999").unwrap();
    assert_eq!(app.windows.iter().map(|w| w.id).collect::<Vec<_>>(), [10, 20, 30, 40]);
    assert_eq!((app.active_idx, app.last_window_idx), (2, 1));
    assert_eq!(app.status_message.as_ref().unwrap().0, "unlink-window: can't find window: @999");

    let mut app = AppState::new("unlink-one".to_string());
    app.windows.push(window(10));
    assert_eq!(app.active_idx, 0);
    assert_eq!(app.last_window_idx, NO_LAST_WINDOW);
    execute_command_string(&mut app, "unlink-window").unwrap();
    assert_eq!(app.windows.iter().map(|w| w.id).collect::<Vec<_>>(), [10]);
    assert_eq!(app.active_idx, 0);
    assert_eq!(app.last_window_idx, NO_LAST_WINDOW);
    assert!(app.status_message.is_none());
}
