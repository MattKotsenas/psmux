// Per-pane client-side selection yield: a pane whose app explicitly enabled
// a mouse protocol (DECSET 1000/1002/1003) ships `wants_mouse: true` in its
// layout leaf, and the client skips its own drag selection for clicks in
// that pane so the app receives press/drag/release itself (gaviero, nvim
// `set mouse=a`, opencode).  Complements the global `mouse-selection off`
// escape hatch from issue #245.

use super::*;

/// Old servers (and the squelch fast path) emit leaves without the field —
/// serde must default it to false so behavior is unchanged for them.
#[test]
fn leaf_json_without_wants_mouse_defaults_false() {
    let json = r#"{"type":"leaf","id":3,"rows":24,"cols":80,
        "cursor_row":0,"cursor_col":0,"active":true,"copy_mode":false,
        "scroll_offset":0,"sel_start_row":null,"sel_start_col":null,
        "sel_end_row":null,"sel_end_col":null}"#;
    let leaf: LayoutJson = serde_json::from_str(json).expect("legacy leaf must parse");
    match leaf {
        LayoutJson::Leaf { id, wants_mouse, .. } => {
            assert_eq!(id, 3);
            assert!(!wants_mouse, "missing wants_mouse must default to false");
        }
        _ => panic!("expected leaf"),
    }
}

/// Shape check against the streaming dump writer: the header it emits
/// (`"alternate_screen":…,"wants_mouse":…,"hide_cursor":…`) must
/// deserialize with the flag intact.
#[test]
fn leaf_json_with_wants_mouse_true_parses() {
    let json = r#"{"type":"leaf","id":7,"rows":24,"cols":80,
        "cursor_row":1,"cursor_col":2,"alternate_screen":true,
        "wants_mouse":true,"hide_cursor":false,"cursor_shape":0,
        "active":true,"copy_mode":false,"scroll_offset":0,
        "sel_start_row":null,"sel_start_col":null,
        "sel_end_row":null,"sel_end_col":null,
        "rows_v2":[],"content":[],"title":null}"#;
    let leaf: LayoutJson = serde_json::from_str(json).expect("leaf must parse");
    match leaf {
        LayoutJson::Leaf { id, wants_mouse, .. } => {
            assert_eq!(id, 7);
            assert!(wants_mouse);
        }
        _ => panic!("expected leaf"),
    }
}

#[test]
fn pane_wants_mouse_json_matches_only_the_flagged_pane() {
    let json = r#"{"type":"split","kind":"Horizontal","sizes":[50,50],
        "children":[
          {"type":"leaf","id":0,"rows":24,"cols":40,
           "cursor_row":0,"cursor_col":0,"active":false,"copy_mode":false,
           "scroll_offset":0,"sel_start_row":null,"sel_start_col":null,
           "sel_end_row":null,"sel_end_col":null},
          {"type":"leaf","id":1,"rows":24,"cols":40,
           "cursor_row":0,"cursor_col":0,"wants_mouse":true,
           "active":true,"copy_mode":false,"scroll_offset":0,
           "sel_start_row":null,"sel_start_col":null,
           "sel_end_row":null,"sel_end_col":null}
        ]}"#;
    let layout: LayoutJson = serde_json::from_str(json).expect("split must parse");
    assert!(
        !pane_wants_mouse_json(&layout, 0),
        "shell pane (no mouse protocol) must NOT yield client selection"
    );
    assert!(
        pane_wants_mouse_json(&layout, 1),
        "pane with wants_mouse:true must yield client selection"
    );
    assert!(
        !pane_wants_mouse_json(&layout, 99),
        "unknown pane id must default to false (keep client selection)"
    );
}

#[test]
fn mouse_aware_pane_yields_selection_by_default() {
    assert!(!client_selection_owns_drag(true, false, true));
}

#[test]
fn force_option_keeps_psmux_selection_in_mouse_aware_pane() {
    assert!(client_selection_owns_drag(true, true, true));
}

#[test]
fn force_option_does_not_enable_globally_disabled_selection() {
    assert!(!client_selection_owns_drag(false, true, true));
}

#[test]
fn shell_pane_keeps_selection_without_force() {
    assert!(client_selection_owns_drag(true, false, false));
}
