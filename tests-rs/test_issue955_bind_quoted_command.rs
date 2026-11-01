// Issue #955: a binding whose command is one quoted argument
// (`bind r 'set -g @r 1'`, `bind x 'a ; b'`) is parsed again as a command
// string, as tmux's bind-key does with the key and exactly one more argument
// (cmd-bind-key.c:91-92 at tag 3.8, cmd_parse_from_string). psmux kept the
// quoted text as one command named by all of it, so the key ran nothing.

use super::*;

fn app() -> crate::types::AppState {
    crate::types::AppState::new("test_session".to_string())
}

fn bound(app: &crate::types::AppState, table: &str, key: &str) -> Option<String> {
    let k = normalize_key_for_binding(parse_key_name(key)?);
    app.key_tables.get(table)?.iter().find(|b| b.key == k).map(|b| crate::commands::format_action(&b.action))
}

fn chain_len(app: &crate::types::AppState, table: &str, key: &str) -> usize {
    let k = normalize_key_for_binding(parse_key_name(key).unwrap());
    match &app.key_tables[table].iter().find(|b| b.key == k).unwrap().action {
        crate::types::Action::CommandChain(c) => c.len(),
        _ => 1,
    }
}

fn v(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

#[test]
fn a_quoted_list_is_its_commands() {
    assert_eq!(bind_command_list("'set -g @a 1 ; set -g @b 1'"), v(&["set -g @a 1", "set -g @b 1"]));
    assert_eq!(bind_command_list("\"set -g @d 1 ; set -g @e 1\""), v(&["set -g @d 1", "set -g @e 1"]));
    assert_eq!(bind_command_list("'set -g @a 1 \\; set -g @b 1'"), v(&["set -g @a 1", "set -g @b 1"]));
    // The docs' example: a `;` that ends a word.
    assert_eq!(bind_command_list("'set -g @a 1; set -g @b 2'"), v(&["set -g @a 1", "set -g @b 2"]));
}

#[test]
fn a_quoted_command_is_that_command() {
    assert_eq!(bind_command_list("'set -g @c 1'"), v(&["set -g @c 1"]));
    assert_eq!(bind_command_list("\"select-pane -L\""), v(&["select-pane -L"]));
}

#[test]
fn quotes_inside_are_the_commands_own() {
    assert_eq!(bind_command_list("'rename-window \"x y\"'"), v(&["rename-window \"x y\""]));
    assert_eq!(bind_command_list("'set -g @k \"v w\"'"), v(&["set -g @k \"v w\""]));
    // A `;` quoted inside the string stays in its command.
    assert_eq!(bind_command_list("'display \"a ; b\"'"), v(&["display \"a ; b\""]));
    // An escaped quote inside double quotes.
    assert_eq!(bind_command_list("\"display \\\"a ; b\\\"\""), v(&["display \"a ; b\""]));
}

#[test]
fn other_forms_are_read_as_before() {
    // Several arguments: a quoted one is an argument of the command.
    assert_eq!(bind_command_list("display 'a ; b'"), v(&["display 'a ; b'"]));
    assert_eq!(bind_command_list("'display' 'a b'"), v(&["'display' 'a b'"]));
    assert_eq!(bind_command_list("set -g @a 1 \\; set -g @b 2"), v(&["set -g @a 1", "set -g @b 2"]));
    assert_eq!(bind_command_list("{ set -g @a 1 ; set -g @b 2 }"), v(&["set -g @a 1", "set -g @b 2"]));
    assert_eq!(bind_command_list("select-pane -L"), v(&["select-pane -L"]));
}

#[test]
fn a_config_binding_of_a_quoted_command_runs_it() {
    let mut app = app();
    parse_config_content(
        &mut app,
        "bind r 'set -g @r 1'\nbind -n F5 'set -g @a 1 ; set -g @b 1'\nbind -n F11 'rename-window \"x y\"'\n",
    );
    assert!(app.config_warnings.is_empty(), "{:?}", app.config_warnings);
    assert_eq!(bound(&app, "prefix", "r").unwrap(), "set -g @r 1");
    assert_eq!(chain_len(&app, "root", "F5"), 2);
    assert_eq!(bound(&app, "root", "F5").unwrap(), "set -g @a 1 \\; set -g @b 1");
    assert_eq!(bound(&app, "root", "F11").unwrap(), "rename-window \"x y\"");
}

#[test]
fn the_server_bind_path_reads_it_the_same_way() {
    // The bind-key the command prompt sends goes through bind_commands.
    let aliases = std::sync::Arc::new(std::sync::RwLock::new(
        crate::command_alias::CommandAliases::with_defaults(),
    ));
    assert_eq!(
        bind_commands(&aliases, "'set -g @p 1 ; set -g @q 1'"),
        v(&["set -g @p 1", "set -g @q 1"])
    );
    // An alias inside the quotes is expanded, as tmux expands it at bind time.
    assert_eq!(bind_commands(&aliases, "'split-pane -h'"), v(&["split-window -h"]));
}
