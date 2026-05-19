// Phase 2 + Phase 3 integration smoke test: feed the literal bytes emitted by
// the pwsh profile snippet through vt100::Parser and verify shell_command()
// resolves correctly across a full prompt-command-done-prompt-command cycle.
//
// This pairs the psmux parser (Phase 2 of #299) with the pwsh emitter
// (Phase 3 — the Enable-OSC133Integration.ps1 snippet) end-to-end.

#[test]
fn phase3_pwsh_snippet_emissions_round_trip_through_parser() {
    // Bytes captured verbatim from running Enable-OSC133Integration.ps1 in a
    // -NoProfile pwsh and synthesizing two prompt cycles with two commands:
    //   1. `copilot --yolo`
    //   2. `dotnet build`
    let stream = b"\
\x1b]7;file://MATTKOT-SURFACE/C:/Projects/dotfiles\x07\
\x1b]133;A\x07\
\x1b]133;B\x07\
\x1b]133;C;cmdline_url=copilot%20--yolo\x07\
output of copilot --yolo\n\
\x1b]133;D;0\x07\
\x1b]7;file://MATTKOT-SURFACE/C:/Projects/dotfiles\x07\
\x1b]133;A\x07\
\x1b]133;B\x07\
\x1b]133;C;cmdline_url=dotnet%20build\x07";

    let mut p = vt100::Parser::new(24, 80, 0);

    // Feed it chunk by chunk to also exercise the cross-chunk stitching path
    // the OSC parser added in commit a2b353a.
    let chunks: Vec<&[u8]> = stream.chunks(13).collect();
    for chunk in chunks {
        p.process(chunk);
    }

    // After processing the full stream, the parser should be in the state
    // "command 'dotnet build' is running" because the last sequence was
    // OSC 133;C;cmdline_url=dotnet%20build with no subsequent D.
    assert_eq!(
        p.screen().shell_command(),
        Some("dotnet build"),
        "final shell_command should reflect the last C-without-D"
    );

    // OSC 7 should have set the path. Note: parse_osc7_uri strips the
    // hostname and keeps the leading slash from the URL, so the captured
    // form `file://host/C:/Projects/dotfiles` becomes `/C:/Projects/dotfiles`.
    assert_eq!(
        p.screen().path(),
        Some("/C:/Projects/dotfiles"),
        "OSC 7 from the snippet must populate Screen::path"
    );
}

#[test]
fn phase3_pwsh_snippet_idle_state_after_d() {
    // Same stream but trimmed at OSC 133;D — should be Idle, no command.
    let stream = b"\
\x1b]7;file://host/some/path\x07\
\x1b]133;A\x07\
\x1b]133;B\x07\
\x1b]133;C;cmdline_url=ls\x07\
output\n\
\x1b]133;D;0\x07";

    let mut p = vt100::Parser::new(24, 80, 0);
    p.process(stream);

    assert_eq!(
        p.screen().shell_command(),
        None,
        "after OSC 133;D the shell should be reported as idle"
    );
}
