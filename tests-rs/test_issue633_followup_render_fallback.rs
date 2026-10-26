//! #633 follow up: the per-frame render path must never end the server over a
//! bad render option.
//!
//! The #633 refactor gave `expand_status_formats` an `io::Result` return and
//! both `run_server` call sites used `?`, so a `pane-border-indicators` value
//! that escaped catalog validation (every CLI/config write route validates
//! today, but any future direct write into `user_options` would not) turned
//! into `run_server` returning `Err` — total session loss for a cosmetic
//! option. The follow up makes the expansion infallible: an unparseable value
//! degrades to the catalog default, exactly the fallback the client applies to
//! a missing field. Same treatment for `append_client_render_options_json` at
//! the call sites: a malformed buffer skips the append instead of killing the
//! server (its pre-#633 behavior was a quiet no-op guard).
//!
//! These tests poison `user_options` directly, deliberately bypassing
//! set-option/config validation, because that is precisely the only route the
//! failure could ever arrive by.

use super::*;

fn mk_app() -> AppState {
    let mut app = AppState::new("issue633_followup".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

// ── 1. A poisoned pane-border-indicators degrades to the default ──
#[test]
fn poisoned_pane_border_indicators_falls_back_to_default() {
    let mut app = mk_app();
    app.user_options
        .insert("pane-border-indicators".to_string(), "bogus".to_string());

    // Before the follow up this returned Err and `?` in run_server ended the
    // server; now it must produce a frame with the catalog default.
    let formats = expand_status_formats(&app, "");
    assert_eq!(
        formats.client_render_options.pane_border_indicators,
        Some(crate::pane_border::PaneBorderIndicators::default()),
        "an invalid pane-border-indicators value must degrade to the default, \
         never propagate an error into the per-frame render path"
    );
}

// ── 2. Empty string is invalid too, and must also degrade ──
#[test]
fn empty_pane_border_indicators_falls_back_to_default() {
    let mut app = mk_app();
    app.user_options
        .insert("pane-border-indicators".to_string(), String::new());
    let formats = expand_status_formats(&app, "");
    assert_eq!(
        formats.client_render_options.pane_border_indicators,
        Some(crate::pane_border::PaneBorderIndicators::default()),
    );
}

// ── 3. Valid values are untouched by the fallback ──
#[test]
fn valid_pane_border_indicators_still_pass_through() {
    for (raw, want) in [
        ("off", crate::pane_border::PaneBorderIndicators::Off),
        ("colour", crate::pane_border::PaneBorderIndicators::Colour),
        ("arrows", crate::pane_border::PaneBorderIndicators::Arrows),
        ("both", crate::pane_border::PaneBorderIndicators::Both),
    ] {
        let mut app = mk_app();
        app.user_options
            .insert("pane-border-indicators".to_string(), raw.to_string());
        let formats = expand_status_formats(&app, "");
        assert_eq!(
            formats.client_render_options.pane_border_indicators,
            Some(want),
            "valid value {raw} must not be replaced by the fallback"
        );
    }
}

// ── 4. The default path (option unset) is unchanged ──
#[test]
fn unset_pane_border_indicators_is_the_default() {
    let app = mk_app();
    let formats = expand_status_formats(&app, "");
    assert_eq!(
        formats.client_render_options.pane_border_indicators,
        Some(crate::pane_border::PaneBorderIndicators::Colour),
    );
}

// ── 5. append on a malformed buffer reports Err without touching the buffer ──
// The call sites now swallow this Err (skip the append) instead of `?`-ing it
// into run_server; the helper itself must keep refusing so the contract stays
// testable and the buffer stays intact for the fallback path.
#[test]
fn append_on_malformed_buffer_errs_and_leaves_buffer_intact() {
    let app = mk_app();
    let formats = expand_status_formats(&app, "");
    let mut buf = String::from("not a json object");
    let before = buf.clone();
    let res = append_client_render_options_json(&mut buf, &formats.client_render_options);
    assert!(res.is_err(), "a buffer without a closing brace must be refused");
    assert_eq!(buf, before, "a refused append must not corrupt the buffer");
}
