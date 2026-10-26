// #712 audit: a lone quote both starts and ends with itself, and the quote
// stripper sliced [1..0], which panicked the server on
// `new-window "/bin/bash -c '"`.

use super::{detect_bash_c_wrapper, parse_bash_env_script};

#[test]
fn lone_quote_after_bash_c_is_kept_verbatim() {
    assert_eq!(detect_bash_c_wrapper("/bin/bash -c '"), Some(("'", "bash")));
    assert_eq!(detect_bash_c_wrapper("/bin/sh -c \""), Some(("\"", "sh")));
}

#[test]
fn quoted_script_is_still_unwrapped() {
    assert_eq!(detect_bash_c_wrapper("/bin/bash -c 'echo hi'"), Some(("echo hi", "bash")));
    assert_eq!(detect_bash_c_wrapper("/bin/bash -c ''"), Some(("", "bash")));
}

#[test]
fn export_with_lone_quote_value_does_not_panic() {
    let (_removes, sets, _rest) = parse_bash_env_script("export X=\"");
    assert_eq!(sets.len(), 1);
    assert_eq!(sets[0].0, "X");
    let (_r, sets, _f) = parse_bash_env_script("export Y='v'");
    assert_eq!(sets[0], ("Y".to_string(), "v".to_string()));
}
