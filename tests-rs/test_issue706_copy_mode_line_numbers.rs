// Issue #706 (noted there): `set -g copy-mode-line-numbers <mode>` in a config
// file was reported as `unknown option` although the option exists and the
// value took effect. The config path had no arm for it, so it reached the
// fallthrough that stores AND warns. Its three siblings read back from
// user_options the same way had the same false warning.
//
// tmux declares copy-mode-line-numbers as a CHOICE option
// (off/default/absolute/relative/hybrid, options-table.c), so a value outside
// that list is refused rather than stored.

use super::*;

fn app() -> AppState {
    AppState::new("cfgwarn706_test".to_string())
}

fn load(a: &mut AppState, text: &str) {
    crate::config::parse_config_content(a, text);
}

#[test]
fn every_mode_is_accepted_without_a_warning_and_takes_effect() {
    for mode in crate::copy_line_numbers::CHOICES {
        let mut a = app();
        load(&mut a, &format!("set -g copy-mode-line-numbers {}\n", mode));
        assert!(a.config_warnings.is_empty(), "{}: {:?}", mode, a.config_warnings);
        assert_eq!(a.user_options.get("copy-mode-line-numbers").map(String::as_str), Some(*mode));
    }
}

#[test]
fn setw_and_set_gw_forms_do_not_warn_either() {
    let mut a = app();
    load(&mut a, "setw -g copy-mode-line-numbers relative\nset -gw copy-mode-line-numbers hybrid\n");
    assert!(a.config_warnings.is_empty(), "{:?}", a.config_warnings);
    assert_eq!(a.user_options.get("copy-mode-line-numbers").map(String::as_str), Some("hybrid"));
}

#[test]
fn an_invalid_mode_is_refused_like_tmux_and_named_in_the_warning() {
    let mut a = app();
    load(&mut a, "set -g copy-mode-line-numbers absolute\nset -g copy-mode-line-numbers bogus\n");
    assert_eq!(a.config_warnings.len(), 1, "{:?}", a.config_warnings);
    let w = &a.config_warnings[0];
    assert!(w.contains("copy-mode-line-numbers") && w.contains("bogus"), "{}", w);
    assert!(!w.contains("unknown option"), "{}", w);
    // The earlier valid value stands.
    assert_eq!(a.user_options.get("copy-mode-line-numbers").map(String::as_str), Some("absolute"));
}

#[test]
fn the_sibling_options_read_from_user_options_do_not_warn() {
    let mut a = app();
    load(&mut a, concat!(
        "set -g copy-mode-line-number-style fg=red\n",
        "set -g copy-mode-current-line-number-style fg=blue\n",
        "set -g pane-border-lines double\n",
    ));
    assert!(a.config_warnings.is_empty(), "{:?}", a.config_warnings);
    assert_eq!(a.user_options.get("copy-mode-line-number-style").map(String::as_str), Some("fg=red"));
    assert_eq!(a.user_options.get("copy-mode-current-line-number-style").map(String::as_str), Some("fg=blue"));
    assert_eq!(a.user_options.get("pane-border-lines").map(String::as_str), Some("double"));
}

#[test]
fn a_real_typo_still_warns() {
    let mut a = app();
    load(&mut a, "set -g copy-mode-line-numbrs relative\n");
    assert!(a.config_warnings.iter().any(|w| w.contains("unknown option 'copy-mode-line-numbrs'")),
        "{:?}", a.config_warnings);
}
