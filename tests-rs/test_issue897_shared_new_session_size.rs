// Issue #897 follow up (shared server, #798): a new-session whose first pane
// would be too big is refused before anything is created, because the
// allocation failure of one session aborts the process every session shares.
// No server, socket or pane is started.

use super::*;

fn args(width: Option<u16>, height: Option<u16>) -> NewSessionArgs {
    NewSessionArgs {
        width,
        height,
        ..NewSessionArgs::default()
    }
}

#[test]
fn sizes_up_to_the_cell_limit_are_accepted() {
    for (width, height) in [
        (None, None),
        (Some(80), Some(24)),
        (Some(2048), Some(2048)),
        (Some(4096), Some(1024)),
        (Some(65535), Some(64)),
        (Some(60000), None),
        (Some(40000), Some(0)),
    ] {
        assert_eq!(
            new_session_size_error(&args(width, height)),
            None,
            "{:?}x{:?}",
            width,
            height
        );
    }
}

#[test]
fn sizes_over_the_cell_limit_are_refused() {
    for (width, height) in [
        (Some(2049), Some(2048)),
        (Some(4097), Some(1024)),
        (Some(65535), Some(65535)),
        (None, Some(60000)),
        (Some(0), Some(60000)),
        (Some(1), Some(60000)),
    ] {
        assert!(
            new_session_size_error(&args(width, height)).is_some(),
            "{:?}x{:?}",
            width,
            height
        );
    }
}

#[test]
fn the_refusal_names_the_size_the_pane_would_get() {
    assert_eq!(
        new_session_size_error(&args(Some(0), Some(60000))).as_deref(),
        Some("size too large: 120x60000 is 7200000 cells, more than 4194304")
    );
    assert_eq!(
        new_session_size_error(&args(Some(65535), Some(65535))).as_deref(),
        Some("size too large: 65535x65535 is 4294836225 cells, more than 4194304")
    );
}
