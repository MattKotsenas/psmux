// Issue #488: bare PageUp must reach the application; tmux binds PPage only
// in the prefix table ("bind PPage copy-mode -u") and copy-mode tables.
use super::*;

#[test]
fn root_defaults_have_no_pageup_binding() {
    // tmux has NO default key bindings in the root table (mouse aside).
    // The old psmux default PageUp -> copy-mode -u swallowed PageUp before
    // pagers/editors could see it.
    assert!(
        crate::help::ROOT_DEFAULTS.iter().all(|(k, _)| *k != "PageUp"),
        "root table must not bind PageUp by default (issue #488)"
    );
}

#[test]
fn prefix_defaults_bind_pageup_to_copy_mode_up() {
    // tmux: bind PPage {{ copy-mode -u }} in the PREFIX table.
    let entry = crate::help::PREFIX_DEFAULTS.iter().find(|(k, _)| *k == "PageUp");
    assert!(entry.is_some(), "prefix table must bind PageUp (tmux parity)");
    assert_eq!(entry.unwrap().1, "copy-mode -u");
}

#[test]
fn key_tables_populated_without_root_pageup() {
    let mut app = AppState::new("t488".to_string());
    crate::config::populate_default_bindings(&mut app);
    if let Some(root) = app.key_tables.get("root") {
        let pageup = crate::config::parse_key_name("PageUp").unwrap();
        let pageup = crate::config::normalize_key_for_binding(pageup);
        assert!(
            root.iter().all(|b| b.key != pageup),
            "populated root table must not contain PageUp"
        );
    }
    let prefix = app.key_tables.get("prefix").expect("prefix table populated");
    let pageup = crate::config::parse_key_name("PageUp").unwrap();
    let pageup = crate::config::normalize_key_for_binding(pageup);
    assert!(
        prefix.iter().any(|b| b.key == pageup),
        "populated prefix table must contain PageUp -> copy-mode -u"
    );
}

#[test]
fn user_can_restore_old_behavior_with_bind_n() {
    // `bind-key -n PageUp copy-mode -u` must still register a root binding
    // for users who WANT the old scroll-on-PageUp behavior.
    let mut app = AppState::new("t488b".to_string());
    crate::config::parse_config_content(&mut app, "bind-key -n PageUp copy-mode -u\n");
    let root = app.key_tables.get("root").expect("root table exists");
    let pageup = crate::config::parse_key_name("PageUp").unwrap();
    let pageup = crate::config::normalize_key_for_binding(pageup);
    assert!(
        root.iter().any(|b| b.key == pageup),
        "explicit bind-key -n PageUp must register in root table"
    );
}
