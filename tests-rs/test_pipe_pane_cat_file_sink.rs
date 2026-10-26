// pipe-pane direct file sink: `cat > file` / `cat >> file` recognition.
//
// The canonical tmux logging idiom cannot work through the Windows sink
// shell (PowerShell's `cat` is Get-Content and never reads stdin), so the
// server services it in-process. These tests pin the parser's contract:
// exactly the plain-redirect shape is recognized; everything else must
// return None and fall through to the shell sink unchanged.

use crate::util::{parse_cat_file_sink, refuse_file_sink_path};

#[test]
fn recognizes_truncate_and_append() {
    assert_eq!(
        parse_cat_file_sink("cat > pane.log"),
        Some(("pane.log".to_string(), false))
    );
    assert_eq!(
        parse_cat_file_sink("cat >> pane.log"),
        Some(("pane.log".to_string(), true))
    );
}

#[test]
fn tolerates_spacing_variants() {
    assert_eq!(
        parse_cat_file_sink("  cat>pane.log  "),
        Some(("pane.log".to_string(), false))
    );
    assert_eq!(
        parse_cat_file_sink("cat>>pane.log"),
        Some(("pane.log".to_string(), true))
    );
    assert_eq!(
        parse_cat_file_sink("cat   >>   pane.log"),
        Some(("pane.log".to_string(), true))
    );
}

#[test]
fn strips_one_level_of_quotes_preserving_spaces_and_backslashes() {
    assert_eq!(
        parse_cat_file_sink(r#"cat > "C:\my logs\pane.log""#),
        Some((r"C:\my logs\pane.log".to_string(), false))
    );
    assert_eq!(
        parse_cat_file_sink(r"cat >> 'C:\my logs\pane.log'"),
        Some((r"C:\my logs\pane.log".to_string(), true))
    );
}

#[test]
fn rejects_non_cat_commands() {
    assert_eq!(parse_cat_file_sink("catalog > f"), None);
    assert_eq!(parse_cat_file_sink("category>f"), None);
    assert_eq!(parse_cat_file_sink("cat"), None);
    assert_eq!(parse_cat_file_sink("cat pane.log"), None);
    assert_eq!(parse_cat_file_sink("tee pane.log"), None);
    assert_eq!(parse_cat_file_sink(""), None);
}

#[test]
fn rejects_shapes_that_need_a_real_shell() {
    // Options on cat: not the plain idiom.
    assert_eq!(parse_cat_file_sink("cat -A > f"), None);
    // Unquoted path with whitespace: ambiguous under shell word splitting.
    assert_eq!(parse_cat_file_sink("cat > my logs.txt"), None);
    // Further redirection / piping / quoting inside the path.
    assert_eq!(parse_cat_file_sink("cat > f > g"), None);
    assert_eq!(parse_cat_file_sink("cat > f | sort"), None);
    assert_eq!(parse_cat_file_sink("cat > f&"), None);
    assert_eq!(parse_cat_file_sink(r#"cat > "a" "b""#), None);
    assert_eq!(parse_cat_file_sink("cat > ''"), None);
    assert_eq!(parse_cat_file_sink("cat > "), None);
    assert_eq!(parse_cat_file_sink("cat >"), None);
}

#[test]
fn matches_cat_case_insensitively_like_the_powershell_alias() {
    assert_eq!(
        parse_cat_file_sink("CAT > pane.log"),
        Some(("pane.log".to_string(), false))
    );
    assert_eq!(
        parse_cat_file_sink("Cat >> pane.log"),
        Some(("pane.log".to_string(), true))
    );
    // Case-insensitivity must not loosen the word boundary.
    assert_eq!(parse_cat_file_sink("CATALOG > f"), None);
}

#[test]
fn refuses_paths_that_can_stall_or_hit_a_device() {
    // UNC in every spelling; `\\?\C:\` (extended-length local) is fine.
    assert!(refuse_file_sink_path(r"\\server\share\pane.log").is_some());
    assert!(refuse_file_sink_path("//server/share/pane.log").is_some());
    assert!(refuse_file_sink_path(r"\\?\UNC\server\share\pane.log").is_some());
    assert!(refuse_file_sink_path(r"\\.\PhysicalDrive0").is_some());
    assert!(refuse_file_sink_path(r"\\?\C:\logs\pane.log").is_none());
    // DOS reserved device names, bare / with extension / in a directory /
    // any case. `CON.log` still opens the console device on Windows.
    assert!(refuse_file_sink_path("CON").is_some());
    assert!(refuse_file_sink_path("con.log").is_some());
    assert!(refuse_file_sink_path(r"C:\logs\CON").is_some());
    assert!(refuse_file_sink_path(r"C:\logs\Nul.txt").is_some());
    assert!(refuse_file_sink_path("COM1").is_some());
    assert!(refuse_file_sink_path("lpt9.log").is_some());
    // DOS-style trailing colon is still the device.
    assert!(refuse_file_sink_path("nul:").is_some());
    assert!(refuse_file_sink_path("NUL:").is_some());
    assert!(refuse_file_sink_path("COM1:").is_some());
    // Near-misses are ordinary filenames.
    assert!(refuse_file_sink_path("CONS.log").is_none());
    assert!(refuse_file_sink_path("COM0").is_none());
    assert!(refuse_file_sink_path("COM10").is_none());
    assert!(refuse_file_sink_path(r"C:\logs\console.log").is_none());
    assert!(refuse_file_sink_path(r"C:\logs\pane.log").is_none());
}

#[test]
fn rejects_anything_a_shell_would_expand_or_chain() {
    // Expansion: intercepting these would take the LITERAL text as a
    // filename while the user meant the expanded value.
    assert_eq!(parse_cat_file_sink("cat > $HOME/pane.log"), None);
    assert_eq!(parse_cat_file_sink("cat > ~/pane.log"), None);
    assert_eq!(parse_cat_file_sink("cat > $(date).log"), None);
    assert_eq!(parse_cat_file_sink("cat > `date`.log"), None);
    assert_eq!(parse_cat_file_sink("cat > %TEMP%.log"), None);
    assert_eq!(parse_cat_file_sink("cat > a^b.log"), None);
    assert_eq!(parse_cat_file_sink(r#"cat > "$LOG""#), None);
    assert_eq!(parse_cat_file_sink("cat > '`x`.log'"), None);
    // Chaining hidden in the "path".
    assert_eq!(parse_cat_file_sink("cat > out.log;calc"), None);
    // tmux format variables: tmux would expand these, we would not — so
    // never intercept them as literal filenames.
    assert_eq!(parse_cat_file_sink("cat >> output.#I-#P"), None);
    assert_eq!(parse_cat_file_sink(r#"cat > "pane #{pane_id}.log""#), None);
    // A tilde later in the name is a plain filename character.
    assert_eq!(
        parse_cat_file_sink("cat > pane~1.log"),
        Some(("pane~1.log".to_string(), false))
    );
}
