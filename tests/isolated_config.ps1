# isolated_config.ps1
#
# Gives a suite a config of its own so it never inherits the machine's config
# (discussion #748). Without -f or PSMUX_CONFIG_FILE, psmux loads the first of
# ~/.psmux.conf, ~/.psmuxrc, ~/.tmux.conf and ~/.config/psmux/psmux.conf, so a
# developer with `set -g base-index 1` saw every suite that targets `:0` fail
# with "can't find window: 0". PSMUX_CONFIG_FILE replaces all four paths, so a
# suite that points it at a file it owns runs on the defaults everywhere.
#
# This file is not a suite: run_all_tests.ps1 only collects tests\test_*.ps1.
#
# Usage, near the top of a suite, before the first psmux command:
#
#   . "$PSScriptRoot\isolated_config.ps1"
#       Empty config: every option at its default.
#
#   . "$PSScriptRoot\isolated_config.ps1" -Lines @('set -g mouse on', 'set -g history-limit 5000')
#       The defaults plus the lines this suite needs, written in that order.
#
# Afterwards $PsmuxIsolatedConfig holds the path, and $env:PSMUX_CONFIG_FILE
# names it for every psmux this process starts (servers inherit it). Call
# Remove-PsmuxIsolatedConfig in the suite's cleanup to delete the file and put
# back whatever PSMUX_CONFIG_FILE held before; a suite runs in its own pwsh
# process, so skipping that only leaves a small file in TEMP.
#
# A PSMUX_CONFIG_FILE already set when this is dot sourced is replaced on
# purpose: in a developer's shell it is exactly the kind of personal config this
# guards against, and under run_all_tests.ps1 it is an empty file anyway. A suite
# that needs a different config for one step sets $env:PSMUX_CONFIG_FILE itself
# for that step, as many suites already do.

param(
    [string[]]$Lines = @()
)

$script:PsmuxIsolatedConfigPrevious = $env:PSMUX_CONFIG_FILE
$PsmuxIsolatedConfig = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_cfg_" + [guid]::NewGuid().ToString('N').Substring(0, 12) + ".conf")
$psmuxIsolatedText = if ($Lines.Count -gt 0) { ($Lines -join "`n") + "`n" } else { '' }
[System.IO.File]::WriteAllText($PsmuxIsolatedConfig, $psmuxIsolatedText, [System.Text.UTF8Encoding]::new($false))
$env:PSMUX_CONFIG_FILE = $PsmuxIsolatedConfig

function Remove-PsmuxIsolatedConfig {
    if ($PsmuxIsolatedConfig) { Remove-Item -LiteralPath $PsmuxIsolatedConfig -Force -ErrorAction SilentlyContinue }
    if ($script:PsmuxIsolatedConfigPrevious) {
        $env:PSMUX_CONFIG_FILE = $script:PsmuxIsolatedConfigPrevious
    } else {
        Remove-Item Env:PSMUX_CONFIG_FILE -ErrorAction SilentlyContinue
    }
}
