// Issue #841: Escape arrives late in nvim when tmux runs inside a psmux pane
// (psmux -> wsl -> tmux -> nvim), whatever escape-time is set to.
//
// tmux 3.8 asks its outer terminal `CSI 18 t CSI 14 t` whenever the tty has
// no pixel size (tty.c:146-150), which a WSL pty never has, and holds every
// lone Escape for 500 ms while that question is open (tty-keys.c:980-987).
// The inbox console host answers `CSI 18 t` itself but forwards `CSI 14 t`
// (PSMUX_PANE_RAW capture on 26200: `ESC[14t` present, `ESC[18t` absent), and
// psmux answered nothing, so the question stayed open forever.  Measured with
// tmux 3.8 in WSL Ubuntu: every Escape 555 to 571 ms late before this change.
//
// tmux parity, input_csi_dispatch_winops (input.c:2162-2176 in the tmux tree):
//   14 -> "\033[4;%u;%ut"  y * ypixel, x * xpixel
//   15 -> "\033[5;%u;%ut"  y * ypixel, x * xpixel
//   16 -> "\033[6;%u;%ut"  ypixel, xpixel
// with xpixel/ypixel defaulting to 16/32 when unknown (window.c:406-409).
// 18 and 19 (cell size) stay with the console host, which answers them itself
// and does not forward them (#597 xtwinops_is_not_a_query keeps that pinned).

use super::*;

fn sized(rows: u16, cols: u16) -> DecrqmState {
    DecrqmState { rows, cols, cursor_visible: true, ..DecrqmState::default() }
}

fn reply_for(bytes: &[u8], st: &DecrqmState) -> String {
    scan_device_queries(bytes)
        .into_iter()
        .map(|q| device_reply(q, st))
        .collect()
}

#[test]
fn tmux_38_size_probe_draws_one_answer_for_14t() {
    // The exact bytes tmux 3.8 wrote to its tty, from its -vv server log.
    assert_eq!(
        scan_device_queries(b"\x1b[18t\x1b[14t"),
        vec![DeviceQuery::WindowReport(14)]
    );
    assert_eq!(reply_for(b"\x1b[18t\x1b[14t", &sized(29, 120)), "\x1b[4;928;1920t");
}

#[test]
fn csi_14t_reports_pixel_size_like_tmux() {
    assert_eq!(reply_for(b"\x1b[14t", &sized(29, 120)), "\x1b[4;928;1920t");
}

#[test]
fn csi_14t_reply_is_one_tmux_38_accepts() {
    // tty_keys_winsz (tty-keys.c) clears TTY_WINSIZEQUERY only on a reply that
    // sscanf("4;%u;%u") accepts; anything else leaves Escape held.
    let reply = reply_for(b"\x1b[14t", &sized(40, 100));
    let body = reply.strip_prefix("\x1b[").and_then(|r| r.strip_suffix('t')).unwrap();
    let parts: Vec<u32> = body.split(';').map(|p| p.parse().unwrap()).collect();
    assert_eq!(parts, vec![4, 40 * 32, 100 * 16]);
}

#[test]
fn every_pixel_report_tmux_answers() {
    let st = sized(24, 80);
    assert_eq!(reply_for(b"\x1b[15t", &st), "\x1b[5;768;1280t");
    assert_eq!(reply_for(b"\x1b[16t", &st), "\x1b[6;32;16t");
    assert_eq!(reply_for(b"\x1b[18t", &st), "");
    assert_eq!(reply_for(b"\x1b[19t", &st), "");
}

#[test]
fn window_manipulation_that_is_not_a_report_draws_nothing() {
    // tmux pushes and pops titles with 22/23 at startup and exit, and
    // OpenConsole opens every pane with `CSI 1 t`.  None of them is a question.
    let st = sized(24, 80);
    for q in [&b"\x1b[22;0;0t"[..], b"\x1b[23;0;0t", b"\x1b[1t", b"\x1b[8;30;100t", b"\x1b[t"] {
        assert_eq!(reply_for(q, &st), "", "{q:?}");
    }
}
