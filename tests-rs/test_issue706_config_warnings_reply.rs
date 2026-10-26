// Issue #706: the attached client asks the server it started for that server's
// config warnings instead of reading the shared config-warnings.log back. These
// cover the framing of that reply; the end to end proof, with a second server
// writing the shared log throughout, is tests/test_issue706_config_warnings_attached.ps1.
use super::{config_warnings_reply, parse_config_warnings_reply};

#[test]
fn round_trip_keeps_every_warning_in_order() {
    let w = vec![
        "C:\\cfg.conf:1: unknown option 'extended-keys'".to_string(),
        "C:\\cfg.conf:2: unknown option 'terminal-features'".to_string(),
    ];
    assert_eq!(parse_config_warnings_reply(&config_warnings_reply(&w)), Some(w));
}

#[test]
fn a_clean_config_is_an_answer_not_a_missing_one() {
    // Zero warnings must parse as Some(empty): None would send the client to
    // the shared log, which may hold another server's warnings.
    assert_eq!(parse_config_warnings_reply(&config_warnings_reply(&[])), Some(Vec::new()));
}

#[test]
fn a_newline_inside_a_warning_cannot_break_the_count() {
    let w = vec!["a\nb".to_string(), "c".to_string()];
    let parsed = parse_config_warnings_reply(&config_warnings_reply(&w)).unwrap();
    assert_eq!(parsed, vec!["a b".to_string(), "c".to_string()]);
}

#[test]
fn an_old_server_or_a_short_reply_is_not_a_reply() {
    // A server built before the request existed ignores it and closes: "".
    assert_eq!(parse_config_warnings_reply(""), None);
    assert_eq!(parse_config_warnings_reply("unknown command\n"), None);
    // Fewer lines than the header promised is a truncated reply.
    assert_eq!(parse_config_warnings_reply("psmux-config-warnings 2\nonly one\n"), None);
    assert_eq!(parse_config_warnings_reply("psmux-config-warnings x\n"), None);
}
