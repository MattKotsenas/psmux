//! Issue #646: OSC colour reply fragment (`555\`) typed into the session at
//! startup under WezTerm.
//!
//! `query_host_terminal_colors_impl` wrote OSC 10/11, sixteen OSC 4 queries,
//! `CSI ?996n` and a DA1 sentinel, then stopped draining console input the
//! moment the DA1 reply arrived.  WezTerm answers DA1 *first*, so the drain
//! left with sixteen colour replies still in flight; conhost later delivered a
//! torn tail of one of them into the console input queue, and the client's
//! input pump read `555\x1b\` as the keystrokes `5 5 5 Alt+\`.
//!
//! The drain now opens a quiet window on the sentinel instead of leaving on it,
//! and refuses to leave part way through a sequence.  These tests cover the two
//! pure helpers that decide when leaving is safe.

use crate::platform::{ends_mid_sequence, find_csi_terminated, settle_window};

// ─── settle_window: only the VT input path waits ────────────────────────────

#[test]
fn the_vt_input_path_waits_for_the_replies_still_in_flight() {
    // WezTerm, JediTerm, SSH: DA1 measured arriving before the colour replies.
    assert_eq!(settle_window(true), std::time::Duration::from_millis(75));
}

#[test]
fn hosts_that_answer_da1_last_do_not_wait_at_all() {
    // conhost holds 36 bytes when it leaves, Windows Terminal 511, both with an
    // empty queue: nothing is in flight, so the window would be pure startup
    // cost on the two hosts that never had the bug.
    assert_eq!(settle_window(false), std::time::Duration::ZERO);
}

#[test]
fn a_zero_settle_still_demands_the_sentinel_and_a_clean_boundary() {
    // The gate shortens the wait; it must not weaken either guard.  This is the
    // condition the drain evaluates on every idle poll, with settle = 0.
    let may_leave = |b: &[u8]| {
        let settled = std::time::Duration::ZERO >= settle_window(false);
        settled && find_csi_terminated(b, b'c') && !ends_mid_sequence(b)
    };
    // No sentinel yet: keep reading even with no window.
    assert!(!may_leave(b"\x1b]4;0;rgb:5555/5555/5555\x1b\\"));
    // Sentinel in and the buffer clean: leave at once, as before the fix.
    assert!(may_leave(b"\x1b[?61;1;6;7;21;22;23;24;28;32;42;52c"));
    // Sentinel in but a reply half read: the unconditional guard still holds.
    assert!(!may_leave(b"\x1b[?61;1;6;7;21;22;23;24;28;32;42;52c\x1b]4;8;rgb:5555/5555/5"));
}

#[test]
fn the_windows_terminal_shape_leaves_immediately_and_keeps_its_palette() {
    // WT answers the colour replies first and DA1 last, so by the time the
    // sentinel lands the buffer already holds everything and ends at a
    // boundary: zero window, nothing dropped.
    let mut buf: Vec<u8> = Vec::new();
    buf.extend_from_slice(b"\x1b]10;rgb:f2f2/f2f2/f2f2\x1b\\");
    buf.extend_from_slice(b"\x1b]11;rgb:0c0c/0c0c/0c0c\x1b\\");
    for i in 0..16 {
        buf.extend_from_slice(format!("\x1b]4;{};rgb:f2f2/f2f2/f2f2\x1b\\", i).as_bytes());
    }
    buf.extend_from_slice(b"\x1b[?61;4;6;7;14;21;22;23;24;28;32;42;52c");

    assert_eq!(settle_window(false), std::time::Duration::ZERO);
    assert!(find_csi_terminated(&buf, b'c'));
    assert!(!ends_mid_sequence(&buf));

    let hc = crate::platform::parse_host_color_replies(&buf);
    assert_eq!(hc.fg, Some((0xf2, 0xf2, 0xf2)));
    assert_eq!(hc.bg, Some((0x0c, 0x0c, 0x0c)));
    assert!(hc.palette.iter().all(|s| s.is_some()));
}

// ─── ends_mid_sequence: the "never leave holding half a reply" guard ─────────

#[test]
fn empty_buffer_is_at_a_boundary() {
    assert!(!ends_mid_sequence(b""));
}

#[test]
fn plain_text_is_at_a_boundary() {
    assert!(!ends_mid_sequence(b"hello"));
}

#[test]
fn complete_da1_reply_is_at_a_boundary() {
    // Exactly what the drain held when it leaked under WezTerm.
    assert!(!ends_mid_sequence(b"\x1b[?61;6;7;22;23;24;28;32;42c"));
}

#[test]
fn complete_osc4_reply_is_at_a_boundary() {
    assert!(!ends_mid_sequence(b"\x1b]4;8;rgb:5555/5555/5555\x1b\\"));
}

#[test]
fn complete_osc_reply_with_bel_terminator_is_at_a_boundary() {
    assert!(!ends_mid_sequence(b"\x1b]11;rgb:1e1e/1e1e/1e1e\x07"));
}

#[test]
fn torn_osc4_reply_is_mid_sequence() {
    // The tear the reporter reconstructed: the drain would have stopped here
    // and left `555\x1b\` behind for the input pump.
    assert!(ends_mid_sequence(b"\x1b]4;8;rgb:5555/5555/5"));
}

#[test]
fn osc_reply_cut_before_its_string_terminator_is_mid_sequence() {
    assert!(ends_mid_sequence(b"\x1b]4;8;rgb:5555/5555/5555\x1b"));
}

#[test]
fn bare_escape_is_mid_sequence() {
    assert!(ends_mid_sequence(b"\x1b"));
}

#[test]
fn csi_without_its_final_byte_is_mid_sequence() {
    assert!(ends_mid_sequence(b"\x1b[?61;6;7;22"));
}

#[test]
fn osc_opener_alone_is_mid_sequence() {
    assert!(ends_mid_sequence(b"\x1b]"));
}

#[test]
fn dcs_run_is_mid_sequence_until_its_string_terminator() {
    assert!(ends_mid_sequence(b"\x1bP1$r0m"));
    assert!(!ends_mid_sequence(b"\x1bP1$r0m\x1b\\"));
}

#[test]
fn two_byte_escape_completes() {
    // ESC 7 (DECSC) is complete in two bytes.
    assert!(!ends_mid_sequence(b"\x1b7"));
}

#[test]
fn escape_with_intermediates_needs_its_final_byte() {
    assert!(ends_mid_sequence(b"\x1b("));
    assert!(!ends_mid_sequence(b"\x1b(B"));
}

#[test]
fn the_full_wezterm_reply_burst_ends_at_a_boundary() {
    let mut buf: Vec<u8> = Vec::new();
    buf.extend_from_slice(b"\x1b[?61;6;7;22;23;24;28;32;42c");
    buf.extend_from_slice(b"\x1b]10;rgb:cccc/cccc/cccc\x1b\\");
    buf.extend_from_slice(b"\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\");
    for i in 0..16 {
        buf.extend_from_slice(format!("\x1b]4;{};rgb:5555/5555/5555\x1b\\", i).as_bytes());
    }
    assert!(!ends_mid_sequence(&buf));
}

#[test]
fn a_burst_truncated_anywhere_inside_a_reply_reads_as_mid_sequence() {
    let whole = b"\x1b[?61;6;7;22;23;24;28;32;42c\x1b]4;8;rgb:5555/5555/5555\x1b\\";
    // Every cut inside the trailing OSC reply must be reported as mid sequence.
    let osc_start = 28usize;
    for cut in (osc_start + 1)..whole.len() {
        assert!(
            ends_mid_sequence(&whole[..cut]),
            "cut at {} should be mid sequence: {:?}",
            cut,
            String::from_utf8_lossy(&whole[..cut])
        );
    }
    assert!(!ends_mid_sequence(whole));
}

// ─── find_csi_terminated: the sentinel detector the settle window hangs off ──

#[test]
fn da1_reply_is_recognised_as_the_sentinel() {
    assert!(find_csi_terminated(b"\x1b[?61;6;7;22;23;24;28;32;42c", b'c'));
}

#[test]
fn a_partial_da1_reply_is_not_the_sentinel() {
    assert!(!find_csi_terminated(b"\x1b[?61;6;7;22", b'c'));
}

#[test]
fn a_dsr_reply_is_not_the_da1_sentinel() {
    assert!(!find_csi_terminated(b"\x1b[?997;1n", b'c'));
}

#[test]
fn the_sentinel_is_still_found_when_colour_replies_precede_it() {
    // The conhost / Windows Terminal ordering: colours first, DA1 last.
    let mut buf: Vec<u8> = Vec::new();
    for i in 0..16 {
        buf.extend_from_slice(format!("\x1b]4;{};rgb:5555/5555/5555\x1b\\", i).as_bytes());
    }
    buf.extend_from_slice(b"\x1b[?61;6;7;22;23;24;28;32;42c");
    assert!(find_csi_terminated(&buf, b'c'));
    assert!(!ends_mid_sequence(&buf));
}

// ─── the two guards together: what the drain asks on every idle poll ─────────

#[test]
fn drain_may_leave_only_when_the_sentinel_is_in_and_nothing_is_torn() {
    let may_leave = |b: &[u8]| find_csi_terminated(b, b'c') && !ends_mid_sequence(b);

    // No sentinel yet: keep reading.
    assert!(!may_leave(b"\x1b]4;0;rgb:5555/5555/5555\x1b\\"));
    // Sentinel in, buffer clean: leaving is allowed once the queue is quiet.
    assert!(may_leave(b"\x1b[?61;6;7;22;23;24;28;32;42c"));
    // Sentinel in but a reply is half read: keep reading.
    assert!(!may_leave(b"\x1b[?61;6;7;22;23;24;28;32;42c\x1b]4;8;rgb:5555/5555/5"));
    // Sentinel in and the late reply completed: leaving is allowed again.
    assert!(may_leave(b"\x1b[?61;6;7;22;23;24;28;32;42c\x1b]4;8;rgb:5555/5555/5555\x1b\\"));
}

// ─── keeping the late bytes: they must reach the palette parser ─────────────

#[test]
fn late_colour_replies_kept_by_the_settle_window_populate_the_palette() {
    // The WezTerm shape: DA1 first, the colour replies afterwards.  Before the
    // fix the drain kept only the first 28 bytes and the palette came back
    // empty; now the whole buffer is parsed.
    let mut early: Vec<u8> = Vec::new();
    early.extend_from_slice(b"\x1b[?61;6;7;22;23;24;28;32;42c");
    let empty = crate::platform::parse_host_color_replies(&early);
    assert!(!empty.has_any(), "DA1 alone must not yield colours");

    let mut whole = early.clone();
    whole.extend_from_slice(b"\x1b]10;rgb:cccc/cccc/cccc\x1b\\");
    whole.extend_from_slice(b"\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\");
    for i in 0..16 {
        whole.extend_from_slice(format!("\x1b]4;{};rgb:{0:x}{0:x}{0:x}{0:x}/0000/0000\x1b\\", i).as_bytes());
    }
    whole.extend_from_slice(b"\x1b[?997;1n");

    let hc = crate::platform::parse_host_color_replies(&whole);
    assert!(hc.has_any(), "late replies must populate the palette");
    assert_eq!(hc.fg, Some((0xcc, 0xcc, 0xcc)));
    assert_eq!(hc.bg, Some((0x1e, 0x1e, 0x1e)));
    assert_eq!(hc.dark, Some(true));
    for (i, slot) in hc.palette.iter().enumerate() {
        assert!(slot.is_some(), "palette slot {} should be filled", i);
    }
}
