// Regression tests for the reactive CPR (Cursor Position Request) responder.
//
// Root cause (issue: pwsh hangs after lock/unlock):
//   pwsh emits ESC[6n at startup and again after session events such as
//   Win+L / unlock.  psmux's original preemptive ESC[1;1R (written once at
//   spawn time) is long gone by then.  Without a reactive responder pwsh
//   blocks indefinitely.
//
// Fix: the parser thread scans every byte batch for ESC[6n via
// `scan_cpr_query` and sets `cpr_pending`; the server loop calls
// `drain_cpr_pending` which writes ESC[row;colR and clears the flag.

use super::*;

// ── scan_cpr_query ────────────────────────────────────────────────────────

#[test]
fn detects_standalone_cpr_query() {
    assert!(scan_cpr_query(b"\x1b[6n"));
}

#[test]
fn detects_cpr_query_embedded_in_startup_sequence() {
    // This is the exact 88-byte sequence logged for pane=16 when pwsh hung.
    let startup = b"\x1b[6n\x1b[?9001h\x1b[?1004h\x1b[m\x1b]0;pwsh.exe\x07\x1b[?25h";
    assert!(scan_cpr_query(startup));
}

#[test]
fn no_false_positive_for_rmcup_only() {
    assert!(!scan_cpr_query(b"\x1b[?1049l"));
}

#[test]
fn no_false_positive_for_empty_input() {
    assert!(!scan_cpr_query(b""));
}

#[test]
fn no_false_positive_for_plain_text() {
    assert!(!scan_cpr_query(b"hello world"));
}

#[test]
fn no_false_positive_for_partial_sequence() {
    // ESC + '[' without '6n' — must not match
    assert!(!scan_cpr_query(b"\x1b[6"));
    assert!(!scan_cpr_query(b"\x1b[n"));
    assert!(!scan_cpr_query(b"\x1b[6m")); // wrong terminator
}

#[test]
fn detects_cpr_query_at_end_of_buffer() {
    let mut buf = vec![b'X'; 1024];
    buf.extend_from_slice(b"\x1b[6n");
    assert!(scan_cpr_query(&buf));
}

#[test]
fn escapes_without_0x1b_skip_window_scan() {
    // Pre-check: no ESC byte → must be false without scanning
    assert!(!scan_cpr_query(b"[6n"));
}

// ── drain_cpr_pending — response format ──────────────────────────────────
//
// We verify the CPR response string format directly since constructing a
// full Pane (which requires a live MasterPty) is out of scope for a unit
// test.  The format is the same one drain_cpr_pending builds.

#[test]
fn cpr_response_format_is_1_based() {
    // vt100::Parser uses 0-based (row, col); CPR response uses 1-based.
    let mut parser = vt100::Parser::new(24, 80, 0);
    // Move cursor to row 2, col 5 (0-based → 1-based: row=3, col=6)
    parser.process(b"\x1b[3;6H");
    let (r, c) = parser.screen().cursor_position();
    assert_eq!((r, c), (2, 5), "parser uses 0-based coords");
    let response = format!("\x1b[{};{}R", r + 1, c + 1);
    assert_eq!(response, "\x1b[3;6R");
}

#[test]
fn cpr_response_fallback_produces_valid_sequence() {
    // unwrap_or((0,0)) → ESC[1;1R — a valid response that unblocks pwsh
    let (r, c): (u16, u16) = (0, 0);
    let response = format!("\x1b[{};{}R", r + 1, c + 1);
    assert_eq!(response, "\x1b[1;1R");
}

// ── CprScanner — detection across batch boundaries ───────────────────────
//
// The parser thread scans output in coalesced batches. A query that straddles
// a batch boundary is invisible to the per-batch scan_cpr_query (the
// partial-sequence tests above pin that a lone prefix must NOT match), so the
// boundary hides the query, cpr_pending is never set, and the reply is never
// sent. An unanswered ESC[6n then leaves the asker waiting forever — for
// conhost's PSUEDOCONSOLE_INHERIT_CURSOR startup query that means the pane's
// child hangs permanently in ConsoleCreateConnectionObject (reproduced
// deterministically). CprScanner carries the last bytes of the stream between
// scans so a boundary cannot hide the query.

#[test]
fn scanner_detects_in_batch_query() {
    let mut s = CprScanner::new();
    assert!(s.scan(b"\x1b[6n"));
}

#[test]
fn scanner_detects_query_split_at_every_boundary() {
    let q = b"\x1b[6n";
    for cut in 1..q.len() {
        let mut s = CprScanner::new();
        assert!(!s.scan(&q[..cut]), "prefix alone must not fire (cut={})", cut);
        assert!(s.scan(&q[cut..]), "suffix must complete the query (cut={})", cut);
    }
}

#[test]
fn scanner_detects_query_split_across_four_batches() {
    let mut s = CprScanner::new();
    assert!(!s.scan(b"\x1b"));
    assert!(!s.scan(b"["));
    assert!(!s.scan(b"6"));
    assert!(s.scan(b"n"));
}

#[test]
fn scanner_partial_never_completed_does_not_fire() {
    let mut s = CprScanner::new();
    assert!(!s.scan(b"\x1b[6"));
    assert!(!s.scan(b"hello world"));
    assert!(!s.scan(b"n")); // the 'n' no longer completes anything
}

#[test]
fn scanner_detects_query_split_after_long_noise_batches() {
    let mut s = CprScanner::new();
    assert!(!s.scan(&vec![b'X'; 1024]));
    let mut batch = vec![b'Y'; 512];
    batch.extend_from_slice(b"\x1b[6");
    assert!(!s.scan(&batch));
    assert!(s.scan(b"n"));
}
