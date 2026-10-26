//! Issue #658: a pending metadata change must defeat the "NC" fast path.
//!
//! "NC" is two bytes meaning "nothing has changed since the frame you already
//! have". The server used to send it while `meta_dirty` was set, which is the
//! flag a WINDOW SWITCH raises and the only one it raises: `FocusWindowCmd`,
//! `NextWindow` and `PrevWindow` never touch `state_dirty`. The version guard
//! could not cover for that either, because `combined_data_version` sums the
//! data counters of the panes in the ACTIVE window, and two windows whose panes
//! are equally idle sum to the same number.
//!
//! Measured on the shipped binary at e70323c, over one persistent connection
//! that sent `select-window` and `dump-state` back to back so both landed in
//! one server request batch: 5 switches, 5 "NC" replies, 5 runs out of 5. A
//! dump-state sent while nothing had changed was answered "NC" in the same runs,
//! which is what it is for.

use crate::server::{nc_allowed, NcInputs};

/// Everything true, nothing dirty: the case "NC" exists for.
fn quiet() -> NcInputs {
    NcInputs {
        allow_nc: true,
        state_dirty: false,
        meta_dirty: false,
        bell_forward: false,
        has_squelch: false,
        have_cached_frame: true,
        version_matches: true,
        seen_full_frame: true,
    }
}

#[test]
fn nothing_changed_is_answered_nc() {
    assert!(
        nc_allowed(quiet()),
        "with nothing dirty, no bell, no squelch, a cached frame the client has \
         already seen and a matching version, the reply must be the 2 byte NC \
         rather than 50-100KB of unchanged JSON"
    );
}

#[test]
fn a_pending_metadata_change_defeats_nc() {
    let after_window_switch = NcInputs { meta_dirty: true, ..quiet() };
    assert!(
        !nc_allowed(after_window_switch),
        "meta_dirty is set and nothing else is: that is exactly a window switch \
         between two idle windows. Answering NC there tells the client nothing \
         changed while the active window did, and the client has no way to check"
    );
}

#[test]
fn pane_output_still_defeats_nc() {
    assert!(!nc_allowed(NcInputs { state_dirty: true, ..quiet() }));
}

#[test]
fn every_other_reason_still_defeats_nc() {
    assert!(
        !nc_allowed(NcInputs { allow_nc: false, ..quiet() }),
        "a one-shot connection holds no previous frame, so NC would mean nothing to it"
    );
    assert!(!nc_allowed(NcInputs { bell_forward: true, ..quiet() }));
    assert!(!nc_allowed(NcInputs { has_squelch: true, ..quiet() }));
    assert!(!nc_allowed(NcInputs { have_cached_frame: false, ..quiet() }));
    assert!(
        !nc_allowed(NcInputs { version_matches: false, ..quiet() }),
        "the cached frame no longer describes the live state"
    );
    assert!(
        !nc_allowed(NcInputs { seen_full_frame: false, ..quiet() }),
        "this client has never been sent a frame, so there is nothing for NC to \
         refer back to"
    );
}
