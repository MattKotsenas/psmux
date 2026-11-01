// Array elements keyed by a name, as tmux 3.8 keys them (20ef19b4,
// options.c:41-98 and :759-784 at tag 3.8): digits only are a number, any
// other key is a name, numbered elements sort first and named ones after
// them by strcmp, and a value without a key takes the lowest free number.
// Up to 3.7c, and in psmux before this, a key that was no number made the
// name no option at all.

use super::*;

fn spec_of(name: &str) -> &'static ArraySpec {
    spec(name).expect("an array option")
}

fn name(key: &str) -> ArrayKey {
    ArrayKey::Name(key.to_string())
}

fn keys(array: &OptionArray) -> Vec<String> {
    array.iter().map(|(key, _)| key.to_string()).collect()
}

#[test]
fn a_key_is_a_number_or_a_name() {
    assert_eq!(ArrayKey::parse("0"), Some(ArrayKey::Index(0)));
    assert_eq!(ArrayKey::parse("007"), Some(ArrayKey::Index(7)), "digits are kept as their number");
    assert_eq!(ArrayKey::parse("4294967295"), Some(ArrayKey::Index(u32::MAX)));
    assert_eq!(ArrayKey::parse("4294967296"), None, "past UINT_MAX is no key");
    assert_eq!(ArrayKey::parse(""), None);
    for key in ["x", "foo", "-1", "a b", "b[c", "#", "1x"] {
        assert_eq!(ArrayKey::parse(key), Some(name(key)), "{key:?}");
    }
}

#[test]
fn parse_name_takes_a_name_as_the_key() {
    assert_eq!(parse_name("command-alias[foo]"), Ok(("command-alias", Some(name("foo")))));
    assert_eq!(parse_name("terminal-overrides[a b]"), Ok(("terminal-overrides", Some(name("a b")))));
    // The key runs to the first `]`, which must end the name.
    assert_eq!(parse_name("terminal-overrides[b[c]"), Ok(("terminal-overrides", Some(name("b[c")))));
    for bad in ["a[x]y", "a[x]]", "a[]", "a[4294967296]"] {
        assert_eq!(parse_name(bad), Err(format!("invalid option: {}", bad)), "{bad:?}");
    }
}

#[test]
fn numbers_come_first_then_names_in_strcmp_order() {
    // The order tmux 3.8 listed for the same keys.
    let spec = spec_of("terminal-overrides");
    let mut a = OptionArray::default();
    for key in ["foo", "10", "Bar", "a b", "#", "-1", "0", "b[c"] {
        a.apply_set(ArrayKey::parse(key), "v", false, spec);
    }
    assert_eq!(keys(&a), vec!["0", "10", "#", "-1", "Bar", "a b", "b[c", "foo"]);
}

#[test]
fn a_value_without_a_key_takes_the_lowest_free_number() {
    let spec = spec_of("command-alias");
    let mut a = OptionArray::default();
    a.apply_set(Some(name("foo")), "zz=display ZZ", false, spec);
    a.apply_set(Some(ArrayKey::Index(1)), "one=display 1", false, spec);
    a.apply_set(None, "na=display NA", true, spec);
    a.apply_set(None, "nb=display NB", true, spec);
    assert_eq!(keys(&a), vec!["0", "1", "2", "foo"], "-a skips named elements");
    // Without -a the whole array goes, named elements too.
    a.apply_set(None, "p=display P", false, spec);
    assert_eq!(keys(&a), vec!["0"]);
}

#[test]
fn a_named_element_appends_unsets_and_shows() {
    let spec = spec_of("terminal-overrides");
    let mut a = OptionArray::with_default(spec);
    a.apply_set(Some(name("mine")), "xterm*:Tc", false, spec);
    a.apply_set(Some(name("mine")), ":RGB", true, spec);
    assert_eq!(a.get(&name("mine")), Some("xterm*:Tc:RGB"));
    assert_eq!(
        a.show_lines("terminal-overrides", false),
        "terminal-overrides[0] linux*:AX@\nterminal-overrides[mine] xterm*:Tc:RGB\n"
    );
    assert_eq!(a.numbered().count(), 1, "a named element is no numbered one");
    a.apply_unset(Some(name("mine")), spec);
    assert_eq!(keys(&a), vec!["0"]);
    a.apply_unset(Some(name("nosuch")), spec);
    assert_eq!(keys(&a), vec!["0"], "unsetting a name that is not there does nothing");
}

#[test]
fn a_named_alias_works_after_the_numbered_ones() {
    let mut aliases = crate::command_alias::CommandAliases::with_defaults();
    aliases.set("command-alias[foo]", "zz=display -p ZZALIAS", false).unwrap();
    assert_eq!(aliases.get("zz").as_deref(), Some("display -p ZZALIAS"));
    assert_eq!(aliases.value("command-alias[foo]"), "zz=display -p ZZALIAS");
    // The same alias name numbered wins, as cmd_get_alias walks in key order.
    aliases.set("command-alias[9]", "zz=display -p NUMBERED", false).unwrap();
    assert_eq!(aliases.get("zz").as_deref(), Some("display -p NUMBERED"));
    aliases.unset("command-alias[foo]").unwrap();
    aliases.unset("command-alias[9]").unwrap();
    assert!(aliases.get("zz").is_none());
}

#[test]
fn the_server_stores_and_shows_a_named_element() {
    use crate::server::options::{array_option_show_lines, array_option_value, set_array_option, unset_array_option};
    let mut app = crate::types::AppState::new("named_keys".to_string());
    set_array_option(&mut app, "terminal-overrides[mine]", "xterm*:Tc", false).unwrap();
    assert_eq!(array_option_value(&app, "terminal-overrides[mine]"), "xterm*:Tc");
    assert_eq!(array_option_show_lines(&app, "terminal-overrides[mine]", false), "terminal-overrides[mine] xterm*:Tc\n");
    assert_eq!(array_option_show_lines(&app, "terminal-overrides[mine]", true), "xterm*:Tc\n");
    // An element that is not there: tmux 3.8 prints `''`, and with -v an
    // empty line.
    assert_eq!(array_option_show_lines(&app, "terminal-overrides[nosuch]", false), "terminal-overrides[nosuch] ''\n");
    assert_eq!(array_option_show_lines(&app, "terminal-overrides[nosuch]", true), "\n");
    // The client is sent every element's text, named ones too.
    assert!(app.terminal_overrides.iter().any(|(_, entry)| entry == "xterm*:Tc"));
    unset_array_option(&mut app, "terminal-overrides[mine]").unwrap();
    assert_eq!(array_option_value(&app, "terminal-overrides[mine]"), "");
}

#[test]
fn a_named_status_format_element_is_no_line() {
    // status.c:277 at tag 3.8 reads status-format by number only.
    use crate::server::options::set_array_option;
    let mut app = crate::types::AppState::new("named_keys_sf".to_string());
    set_array_option(&mut app, "status-format[x]", "NAMED", false).unwrap();
    assert_eq!(crate::server::helpers::status_format_json(&app), "[]");
    set_array_option(&mut app, "status-format[0]", "ZERO", false).unwrap();
    assert_eq!(crate::server::helpers::status_format_json(&app), "[\"ZERO\"]");
}

#[test]
fn every_route_takes_a_named_key() {
    use crate::server::option_catalog::{is_valid_option_name, validate_option_value};
    for option in ["command-alias[foo]", "terminal-overrides[x]", "codepoint-widths[x]", "status-format[x]"] {
        assert!(is_valid_option_name(option), "{option}");
    }
    assert!(validate_option_value("codepoint-widths[x]", "U+2603=2").is_ok());
    assert!(crate::cli::parse_set_option_args(&["-su", "terminal-overrides[x]"]).validate(false).is_ok());
    // A key that is no key stays no option.
    assert!(!is_valid_option_name("terminal-overrides[]"));
    assert!(!is_valid_option_name("terminal-overrides[x]y"));
}
