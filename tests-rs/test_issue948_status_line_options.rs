// Issue #948: status-bg and status-fg are tmux's colour options of their own
// (options-table.c:1014-1028 at tag 3.8, default `default`), laid over
// status-style when the line is drawn (status.c:248-254), on every route;
// status-justify and status-position take their tmux choices only
// (options.c:1239-1255, `unknown value`); status-left-length and
// status-right-length stop at SHRT_MAX (`value is too large`).
//
// The expected values are what tmux 3.8 (`-f /dev/null`, WSL) printed for the
// same commands, except the X11 and theme colour names: tmux takes them,
// psmux draws neither and refuses them with `bad colour`.

use super::*;
use crate::types::AppState;

fn app() -> AppState {
    AppState::new("test_948".to_string())
}

/// The base style of the status line in the frame the client is sent.
fn drawn(a: &AppState) -> String {
    crate::server::helpers::expand_status_formats(a, &a.status_style).status_style
}

/// The colour the client paints the status line's background with.
fn drawn_bg(a: &AppState) -> Option<ratatui::style::Color> {
    crate::style::parse_tmux_style_components(&drawn(a)).1
}

#[test]
fn colours_are_taken_and_shown_as_tmux_shows_them() {
    for (given, shown) in [
        ("1", "red"),
        ("RED", "red"),
        ("#FF0000", "#ff0000"),
        ("color5", "colour5"),
        ("colour255", "colour255"),
        ("brightred", "brightred"),
        ("91", "brightred"),
        ("terminal", "terminal"),
        ("default", "default"),
    ] {
        assert_eq!(crate::style::option_colour_name(given).as_deref(), Some(shown), "{given}");
    }
    // tmux refuses these with `bad colour` too.
    for refused in ["nosuchcolour", "colour300", "#12345", "07", "8", "bright-red", "idx:3", ""] {
        assert_eq!(crate::style::option_colour_name(refused), None, "{refused}");
    }
    // tmux takes these and psmux cannot draw them.
    for refused in ["aliceblue", "themegreen"] {
        assert_eq!(crate::style::option_colour_name(refused), None, "{refused}");
    }
}

#[test]
fn the_sgr_numbers_draw_as_their_colours() {
    use ratatui::style::Color;
    assert_eq!(crate::style::map_color("1"), Color::Red);
    assert_eq!(crate::style::map_color("7"), Color::White);
    assert_eq!(crate::style::map_color("91"), Color::LightRed);
    assert_eq!(crate::style::map_color("300"), Color::Reset);
}

#[test]
fn a_new_server_shows_default_and_draws_status_style() {
    let a = app();
    assert_eq!(get_option_value(&a, "status-bg"), "default");
    assert_eq!(get_option_value(&a, "status-fg"), "default");
    assert_eq!(drawn(&a), "bg=green,fg=black");
}

#[test]
fn the_config_file_sets_them_and_leaves_status_style_alone() {
    let mut a = app();
    crate::config::parse_config_content(&mut a, "set -g status-bg red\nset -g status-fg white\n");
    assert!(a.config_warnings.is_empty(), "{:?}", a.config_warnings);
    assert_eq!(get_option_value(&a, "status-bg"), "red");
    assert_eq!(get_option_value(&a, "status-fg"), "white");
    assert_eq!(get_option_value(&a, "status-style"), "bg=green,fg=black");
    // tmux 3.8 wrote ESC[37m ESC[41m before its status line for this file.
    assert_eq!(drawn(&a), "bg=green,fg=black,fg=white,bg=red");
    assert_eq!(drawn_bg(&a), Some(ratatui::style::Color::Red));
    assert!(!a.user_options.contains_key("status-bg"), "kept as text");
}

#[test]
fn a_later_status_style_does_not_replace_status_bg() {
    // tmux 3.8 drew this file with ESC[41m, red, and without its first line
    // with ESC[44m, blue.
    let mut a = app();
    crate::config::parse_config_content(&mut a, "set -g status-bg red\nset -g status-style bg=blue\n");
    assert_eq!(drawn_bg(&a), Some(ratatui::style::Color::Red));
    let mut b = app();
    crate::config::parse_config_content(&mut b, "set -g status-style bg=blue\n");
    assert_eq!(drawn_bg(&b), Some(ratatui::style::Color::Blue));
}

#[test]
fn runtime_set_unset_and_append() {
    let mut a = app();
    apply_set_option(&mut a, "status-bg", "1", false).unwrap();
    assert_eq!(get_option_value(&a, "status-bg"), "red");
    assert_eq!(get_option_value(&a, "status-style"), "bg=green,fg=black", "status-style is not rewritten");
    // `-a` sets the colour given, as tmux does for a colour option.
    crate::config::parse_config_content(&mut a, "set -ga status-bg blue\n");
    assert!(a.config_warnings.is_empty(), "{:?}", a.config_warnings);
    assert_eq!(get_option_value(&a, "status-bg"), "blue");
    reset_option_to_default(&mut a, "status-bg");
    assert_eq!(get_option_value(&a, "status-bg"), "default");
    assert_eq!(drawn(&a), "bg=green,fg=black", "-u takes it off again");
}

#[test]
fn default_and_terminal_lay_nothing_over_status_style() {
    let mut a = app();
    apply_set_option(&mut a, "status-bg", "terminal", false).unwrap();
    apply_set_option(&mut a, "status-fg", "default", false).unwrap();
    assert_eq!(drawn(&a), "bg=green,fg=black");
}

#[test]
fn a_bad_colour_is_refused_on_every_route() {
    let mut a = app();
    for value in ["nosuchcolour", "colour300"] {
        assert_eq!(
            crate::server::option_catalog::validate_option_value("status-bg", value).unwrap_err(),
            format!("bad colour: {}", value)
        );
        assert!(apply_set_option(&mut a, "status-fg", value, false).is_err());
    }
    crate::config::parse_config_content(&mut a, "set -g status-bg nosuchcolour\n");
    assert!(a.config_warnings.iter().any(|w| w.contains("bad colour: nosuchcolour")), "{:?}", a.config_warnings);
    assert_eq!(get_option_value(&a, "status-bg"), "default");
    assert_eq!(get_option_value(&a, "status-style"), "bg=green,fg=black");
}

#[test]
fn status_justify_and_status_position_take_their_tmux_choices_only() {
    let validate = crate::server::option_catalog::validate_option_value;
    for value in ["left", "centre", "right", "absolute-centre"] {
        assert!(validate("status-justify", value).is_ok(), "{value}");
    }
    for value in ["middle", "center", "absolute-center", "Left", " left", ""] {
        assert_eq!(validate("status-justify", value).unwrap_err(), format!("unknown value: {}", value));
    }
    for value in ["top", "bottom"] {
        assert!(validate("status-position", value).is_ok(), "{value}");
    }
    assert_eq!(validate("status-position", "middle").unwrap_err(), "unknown value: middle");
    let mut a = app();
    crate::config::parse_config_content(&mut a, "set -g status-justify middle\nset -g status-position middle\n");
    assert_eq!(a.config_warnings.len(), 2, "{:?}", a.config_warnings);
    assert_eq!(get_option_value(&a, "status-justify"), "left");
    assert_eq!(get_option_value(&a, "status-position"), "bottom");
}

#[test]
fn the_status_lengths_stop_at_32767() {
    let validate = crate::server::option_catalog::validate_option_value;
    for name in ["status-left-length", "status-right-length"] {
        assert!(validate(name, "0").is_ok());
        assert!(validate(name, "32767").is_ok());
        assert_eq!(validate(name, "32768").unwrap_err(), "value is too large: 32768");
        assert_eq!(validate(name, "99999").unwrap_err(), "value is too large: 99999");
        assert_eq!(validate(name, "-1").unwrap_err(), "value is too small: -1");
    }
    let mut a = app();
    crate::config::parse_config_content(&mut a, "set -g status-left-length 99999\n");
    assert_eq!(get_option_value(&a, "status-left-length"), "10");
}
