//! Issue #658: an idle attached client must keep a floor under the server push.
//!
//! The server pushes a frame whenever state changes, and that push is what an
//! idle client renders. The idle arm of this decision was a hard `false` on the
//! premise that the push is a reliable notification. It is not guaranteed, the
//! client cannot check that one arrived, and with `force_dump` spent on the
//! request rather than latched there was no retry path left at all: a single
//! push that did not land pinned the display on a stale frame until the user
//! detached and attached again.
//!
//! The floor is not a refresh cadence. It is the longest the display may stay
//! wrong, and it costs one 2 byte "NC" per second when nothing has changed.

use crate::client::{should_request_dump, IDLE_FLOOR_MS};

#[test]
fn an_idle_client_asks_once_per_floor() {
    assert!(
        !should_request_dump(false, false, false, 0),
        "an idle client that just heard from the server has no reason to ask again"
    );
    assert!(
        !should_request_dump(false, false, false, IDLE_FLOOR_MS - 1),
        "one millisecond under the floor is still inside it"
    );
    assert!(
        should_request_dump(false, false, false, IDLE_FLOOR_MS),
        "at the floor the client must re-ask, so a push that never landed costs \
         a second of stale screen and not the rest of the session"
    );
    assert!(should_request_dump(false, false, false, IDLE_FLOOR_MS * 30));
}

#[test]
fn the_floor_is_a_floor_not_a_cadence() {
    // Two orders of magnitude under the 187/sec request/reply spin that commit
    // 9093e03 removed, and a fifth of the 5/sec quiet gate that
    // tests/test_idle_socket_traffic.ps1 asserts idle means.
    assert!(
        IDLE_FLOOR_MS >= 1000,
        "faster than once a second and an idle client is polling again, which is \
         the waste 9093e03 set out to remove"
    );
    assert!(
        IDLE_FLOOR_MS <= 2000,
        "slower than this and a stale screen outlives the user's patience for no \
         measurable saving: idle CPU is the same with the floor as without it"
    );
}

#[test]
fn a_key_or_a_resize_still_asks_immediately() {
    assert!(should_request_dump(true, false, false, 0), "force_dump means now");
    assert!(should_request_dump(false, true, false, 0), "a resize means now");
    assert!(should_request_dump(true, false, true, 0));
}

#[test]
fn typing_keeps_its_own_cap() {
    assert!(
        !should_request_dump(false, false, true, 9),
        "~100fps cap while typing, matching input_poll_ms"
    );
    assert!(should_request_dump(false, false, true, 10));
    assert!(
        should_request_dump(false, false, true, 11),
        "the typing arm must stay well under the idle floor, or a keystroke's \
         echo would wait a second for it"
    );
}
