# psmux test suites

Each `tests\test_*.ps1` file is a PowerShell suite that drives a real psmux.
`tests\run_all_tests.ps1` runs all of them; it kills psmux by name and deletes
`~/.psmux.conf` and `~/.psmuxrc`, so it refuses to start unless
`PSMUX_TEST_SANDBOX=1` says the machine is a disposable one.

## Your own config and a suite run on its own

A psmux started without `-f` or `PSMUX_CONFIG_FILE` loads the first of
`~/.psmux.conf`, `~/.psmuxrc`, `~/.tmux.conf` and `~/.config/psmux/psmux.conf`.
Most suites start their server that way, so a suite run on its own inherits
your config: with `set -g base-index 1`, every suite that targets window `:0`
fails with `can't find window: 0` (discussion #748).

`PSMUX_CONFIG_FILE` replaces all four paths. To run a suite on the defaults,
point it at an empty file first:

```powershell
$env:PSMUX_CONFIG_FILE = Join-Path $env:TEMP 'psmux_empty.conf'
Set-Content -Path $env:PSMUX_CONFIG_FILE -Value '' -NoNewline
pwsh -NoProfile -File tests\test_issue335_copy_search_prompt.ps1
```

There is a cost: a client that runs with `-f` or `PSMUX_CONFIG_FILE` never
claims a warm standby, so a suite run this way tests the cold start path. That
is fine for a suite about a key, a prompt or a target, and wrong for a suite
about the warm pool or start up speed.

That is also why `run_all_tests.ps1` does NOT export the variable. Exporting it
moved every warm pool suite onto the cold path (sweep 2026-10-07_01-38-07:
`new-session` measured 879 ms with a standby armed). Instead the runner clears
`PSMUX_CONFIG_FILE`, removes `~/.psmux.conf` and `~/.psmuxrc` before every
suite as it always has, and refuses to start while `~/.tmux.conf` or
`~/.config/psmux/psmux.conf` exists, because those are yours to move aside.

A suite that does not depend on the warm path can isolate itself by dot sourcing `tests\isolated_config.ps1`
near its top, which writes a config of its own, sets `PSMUX_CONFIG_FILE` for
the suite's process and replaces any value already set:

```powershell
. "$PSScriptRoot\isolated_config.ps1"                              # defaults only
. "$PSScriptRoot\isolated_config.ps1" -Lines @('set -g mouse on')  # defaults plus these lines
# ... at the end
Remove-PsmuxIsolatedConfig
```

`tests\test_issue335_copy_search_prompt.ps1` is the worked example. A suite that
writes a config at a default path and expects psmux to load it at startup must
clear the variable instead (`Remove-Item Env:PSMUX_CONFIG_FILE`), as
`tests\test_issue19_config.ps1` and `tests\test_issue117_xdg_config.ps1` do.
