//! OSC 7 (`ESC ] 7 ; <uri> ST`) round-trip for Windows-shaped paths.
//!
//! `#{pane_path}` is the pure-OSC-7 format variable, and it is the cheap
//! alternative to `#{pane_current_command}` / `#{pane_current_path}`, which
//! reach the pane's foreground process via a full `CreateToolhelp32Snapshot`
//! over every process on the machine (`src/platform.rs`). The status bar can
//! only use the cheap variable if what a Windows shell actually emits parses
//! correctly, so pin that here.
//!
//! The emitter this mirrors is `Invoke-Starship-PreCommand` in
//! dotfiles-Windows (`powershell/core/10-tools.ps1`), which builds the URI with
//! `([uri]$PWD.ProviderPath).AbsoluteUri` — an empty authority and a
//! drive-letter path: `file:///C:/Users/...`.

fn path_after(seq: &[u8]) -> Option<String> {
    let mut parser = vt100_psmux::Parser::default();
    parser.process(seq);
    parser.screen().path().map(str::to_string)
}

/// The exact bytes pwsh emits, with the ST (`ESC \`) terminator.
#[test]
fn osc7_drive_letter_path_with_st_terminator() {
    let seq = b"\x1b]7;file:///C:/Users/Garrett/code\x1b\\";
    assert_eq!(path_after(seq).as_deref(), Some("/C:/Users/Garrett/code"));
}

/// BEL is the other legal terminator; both must land in the same place.
#[test]
fn osc7_accepts_bel_terminator() {
    let seq = b"\x1b]7;file:///C:/Users/Garrett/code\x07";
    assert_eq!(path_after(seq).as_deref(), Some("/C:/Users/Garrett/code"));
}

/// A non-empty authority (UNC / `\\wsl.localhost\...`) must have the host
/// stripped, not folded into the path.
#[test]
fn osc7_unc_authority_is_stripped() {
    let seq = b"\x1b]7;file://wsl.localhost/Ubuntu/home/garrett\x1b\\";
    assert_eq!(path_after(seq).as_deref(), Some("/Ubuntu/home/garrett"));
}

/// `[uri]` percent-encodes spaces and other reserved characters; the parser
/// has to decode them or the basename shown in the status bar is wrong.
#[test]
fn osc7_percent_encoding_is_decoded() {
    let seq = b"\x1b]7;file:///C:/Users/Garrett/My%20Code%23One\x1b\\";
    assert_eq!(
        path_after(seq).as_deref(),
        Some("/C:/Users/Garrett/My Code#One")
    );
}

/// `Path::file_name()` is what `#{b:pane_path}` uses. Confirm a forward-slash,
/// drive-letter-prefixed path yields the directory name and not the whole thing.
#[test]
fn basename_of_parsed_path_is_the_directory_name() {
    let seq = b"\x1b]7;file:///C:/Users/Garrett/code/dotgibson\x1b\\";
    let path = path_after(seq).expect("OSC 7 should have been recorded");
    let base = std::path::Path::new(&path)
        .file_name()
        .and_then(|n| n.to_str());
    assert_eq!(base, Some("dotgibson"));
}

/// An OSC 7 with an empty payload must not clobber a previously good value.
#[test]
fn osc7_empty_payload_does_not_clear_previous_path() {
    let mut parser = vt100_psmux::Parser::default();
    parser.process(b"\x1b]7;file:///C:/Users/Garrett/code\x1b\\");
    parser.process(b"\x1b]7;\x1b\\");
    assert_eq!(
        parser.screen().path(),
        Some("/C:/Users/Garrett/code"),
        "an empty OSC 7 should be ignored, not blank the status bar"
    );
}
