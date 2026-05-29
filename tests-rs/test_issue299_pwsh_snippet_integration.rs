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

// ---------------------------------------------------------------------------
// E2E: real captured stream from pwsh + oh-my-posh (pwd: osc7) + snippet
// ---------------------------------------------------------------------------
//
// fixtures/issue299-omp-snippet-e2e.bin is the verbatim byte stream emitted
// by a fresh pwsh subprocess that:
//   1. Loaded oh-my-posh with the user's matt.omp.json (pwd: osc7)
//   2. Sourced Enable-OSC133Integration.ps1
//   3. Rendered a prompt (OMP body + OSC 7 + OSC 133;A/B)
//   4. Synthesized a `copilot --yolo` command (OSC 133;C;cmdline_url=)
//   5. Rendered another prompt (OSC 133;D;0 + OMP body + OSC 7 + 133;A/B)
//
// This proves the division of labor works:
//   - OMP emits OSC 7 (cwd)             via `pwd: osc7` in matt.omp.json
//   - Snippet emits OSC 133;A/B/C/D     via prompt wrapper + Enter handler
//   - Snippet emits OSC 133;C;cmdline_url= for command identity
// All three flow through the same byte stream and psmux's parser surfaces
// both Screen::path() (from OMP's OSC 7) and Screen::shell_command() (from
// the snippet's OSC 133;C;cmdline_url=).

const OMP_SNIPPET_E2E_STREAM: &[u8] =
    include_bytes!("fixtures/issue299-omp-snippet-e2e.bin");

#[test]
fn phase3_e2e_omp_emits_cwd_snippet_emits_command() {
    let mut p = vt100::Parser::new(24, 80, 0);
    p.process(OMP_SNIPPET_E2E_STREAM);

    // OMP (via pwd: osc7) must have populated the OSC 7 path. The exact value
    // depends on the capture machine's hostname + cwd; assert structural
    // properties that hold regardless.
    let path = p.screen().path().expect("OMP should have set OSC 7 path");
    assert!(
        path.contains("dotfiles"),
        "captured stream was from C:\\Projects\\dotfiles; path={path:?}"
    );

    // Snippet must have surfaced the command identity. The capture
    // synthesized `copilot --yolo`; the stream ends with another prompt cycle
    // (133;A/B), which CLEARS shell_command. So the final state is Idle.
    // This is the same correctness check as in phase3_pwsh_snippet_idle_state_after_d
    // but on the real-world stream.
    assert_eq!(
        p.screen().shell_command(),
        None,
        "after the trailing OSC 133;A the shell_command must be cleared"
    );
}

#[test]
fn phase3_e2e_command_identity_visible_mid_stream() {
    // Same captured stream, but trimmed at the point JUST AFTER OSC 133;C;cmdline_url
    // and BEFORE OSC 133;D. At that moment, shell_command must hold
    // the value "copilot --yolo". (OSC 133;D clears it.)
    let stream = OMP_SNIPPET_E2E_STREAM;
    let needle_d = b"\x1b]133;D";
    let d_pos = stream
        .windows(needle_d.len())
        .position(|w| w == needle_d)
        .expect("133;D marker");

    let mut p = vt100::Parser::new(24, 80, 0);
    p.process(&stream[..d_pos]);

    assert_eq!(
        p.screen().shell_command(),
        Some("copilot --yolo"),
        "mid-stream (after OSC 133;C;cmdline_url, before OSC 133;D), shell_command must hold the typed command"
    );

    // And the path is still set from the first prompt's OSC 7.
    let path = p.screen().path().expect("OSC 7 path should still be set");
    assert!(path.contains("dotfiles"));
}
