// Issue #556: color-query replies must be built in query order (scheme, then
// OSC 10 fg, OSC 11 bg, OSC 4 palette) so the single WriteConsoleInputW batch
// the reader thread injects preserves the ordering a real terminal would use.
// Also guards the #473 semantics the sync path must not change: the palette
// burst heuristic and the no-unsolicited-replies rule.
use super::*;

fn campbell() -> crate::types::HostColors {
    crate::types::HostColors::campbell()
}

#[test]
fn scheme_only_builds_scheme_reply_and_nothing_else() {
    let (scheme, osc) = build_color_replies(crate::types::COLOR_QUERY_SCHEME, &campbell());
    assert_eq!(scheme.as_deref(), Some("\x1b[?997;1n"), "campbell is dark → 997;1");
    assert!(osc.is_empty(), "no OSC replies without OSC queries, got: {:?}", osc);
}

#[test]
fn single_palette_query_gets_exactly_one_reply() {
    let (scheme, osc) = build_color_replies(1 << 5, &campbell());
    assert!(scheme.is_none());
    assert_eq!(osc, "\x1b]4;5;rgb:8888/1717/9898\x1b\\");
}

#[test]
fn fg_bg_replies_in_query_order() {
    let bits = crate::types::COLOR_QUERY_FG | crate::types::COLOR_QUERY_BG;
    let (_, osc) = build_color_replies(bits, &campbell());
    let fg_at = osc.find("\x1b]10;").expect("fg reply present");
    let bg_at = osc.find("\x1b]11;").expect("bg reply present");
    assert!(fg_at < bg_at, "OSC 10 reply must precede OSC 11 reply");
}

#[test]
fn burst_includes_fg_bg_and_full_palette_in_order() {
    // Palette index 0 queried → full-burst app (Copilot CLI style, #473):
    // fg/bg included even though ConPTY ate the OSC 10/11 queries.
    let bits: u32 = (1 << 16) - 1; // all 16 palette indexes
    let (_, osc) = build_color_replies(bits, &campbell());
    assert!(osc.starts_with("\x1b]10;"), "burst reply starts with fg");
    let bg_at = osc.find("\x1b]11;").expect("bg present in burst");
    let p0_at = osc.find("\x1b]4;0;").expect("palette 0 present");
    let p15_at = osc.find("\x1b]4;15;").expect("palette 15 present");
    assert!(bg_at < p0_at && p0_at < p15_at, "order: fg, bg, palette 0..15");
}

#[test]
fn non_burst_palette_query_adds_no_fg_bg() {
    let (_, osc) = build_color_replies(1 << 3, &campbell());
    assert!(!osc.contains("\x1b]10;") && !osc.contains("\x1b]11;"),
        "no unsolicited fg/bg for a lone non-zero palette query, got: {:?}", osc);
}

#[test]
fn light_scheme_reports_997_2() {
    let mut hc = campbell();
    hc.dark = Some(false);
    let (scheme, _) = build_color_replies(crate::types::COLOR_QUERY_SCHEME, &hc);
    assert_eq!(scheme.as_deref(), Some("\x1b[?997;2n"));
}

#[test]
fn shared_host_colors_falls_back_to_campbell() {
    // With no client-reported colors and no env override, reader threads must
    // resolve the same Campbell defaults the server loop uses.
    let _lock = crate::util::lock_test_env();
    let orig = std::env::var("PSMUX_HOST_COLORS").ok();
    std::env::remove_var("PSMUX_HOST_COLORS");
    crate::types::set_shared_host_colors(None);
    let hc = crate::types::shared_host_colors();
    assert_eq!(hc, campbell());
    match orig {
        Some(v) => std::env::set_var("PSMUX_HOST_COLORS", v),
        None => std::env::remove_var("PSMUX_HOST_COLORS"),
    }
}

#[test]
fn shared_host_colors_prefers_published_report() {
    let _lock = crate::util::lock_test_env();
    let mut hc = crate::types::HostColors::empty();
    hc.bg = Some((0xFD, 0xF6, 0xE3));
    hc.dark = Some(false);
    crate::types::set_shared_host_colors(Some(hc.clone()));
    assert_eq!(crate::types::shared_host_colors(), hc);
    crate::types::set_shared_host_colors(None);
}
