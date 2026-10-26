# A window `-t` given from a key binding or the command prompt (the in
# server command path, commands.rs) must resolve the way tmux's cmd-find.c
# does (cmd_find_get_window): a target without a colon is a window index or
# name in the current session, then a session name meaning that session's
# current window, and anything else is "can't find window: X". It must never
# fall back to the current window: `kill-window -t keywin` from a binding
# used to kill the CURRENT window because a bare word parsed as a session.
#
# An attached TUI client in a private -L namespace gets its keys written
# into its console with tests\injector.cs. State is checked over the CLI.
# Cleanup: `psmux -L <ns> kill-server`, the client closed by its own PID.

$ErrorActionPreference = 'Continue'
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

Write-Host "psmux: $PSMUX ($(& $PSMUX -V))"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_kbwt_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$ns = 'kbwt_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$S = 'kbwt'
function P { & $PSMUX -L $ns @args 2>&1 }
function Names { return @((P list-windows -t $S -F '#{window_name}') | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
function Current { return ((P display-message -t $S -p '#{window_name}') -join '').Trim() }
function Wait-Until([scriptblock]$cond, [int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 100 }
    return [bool](& $cond)
}

$csc = Get-ChildItem (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4*\csc.exe') -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
$inj = Join-Path $work 'injector.exe'
if ($csc) { & $csc /nologo /optimize "/out:$inj" (Join-Path $PSScriptRoot 'injector.cs') 2>&1 | Out-Null }
if (-not (Test-Path $inj)) { Write-Fail "could not build tests\injector.cs"; exit 1 }

$tui = $null
try {
    P new-session -d -s $S -n main | Out-Null
    P set -g automatic-rename off | Out-Null
    foreach ($n in 'keywin', 'selwin', 'renwin', 'cpwin', 'kpwin', 'spare') { P new-window -d -t $S -n $n | Out-Null }
    # Bindings from a config file: the CLI's own bind-key drops a `-t` inside
    # the bound command (`bind -n F9 rename-window -t w x` stores a bare
    # `rename-window`), a separate client side parsing issue.
    $conf = Join-Path $work 'keys.conf'
    @(
        'bind -n F5 kill-window -t keywin',
        'bind -n F6 kill-window -t nosuchwin',
        'bind -n F7 select-window -t selwin',
        'bind -n F8 select-window -t nosuchwin',
        'bind -n F9 rename-window -t renwin renamed',
        'bind -n F10 rename-window -t nosuchwin bad',
        'bind -n F3 kill-pane -t kpwin',
        'bind -n F4 kill-pane -t nosuchwin',
        "bind -n F12 kill-window -t $S"
    ) | Set-Content -Path $conf -Encoding ASCII
    P source-file $conf | Out-Null
    $keys = (P list-keys) -join "`n"
    if ($keys -match 'F9 rename-window -t renwin renamed') { Write-Pass "bindings loaded" } else { Write-Fail "bindings not loaded as written: $(($keys -split "`n") | Where-Object { $_ -match ' F(5|6|7|8|9|10|12) ' })" }
    $tui = Start-Process -FilePath $PSMUX -ArgumentList '-L', $ns, 'attach', '-t', $S -PassThru
    Start-Sleep -Seconds 3
    function Key([string]$k) { & $inj $tui.Id $k | Out-Null; Start-Sleep -Milliseconds 700 }

    Write-Host "`n[1] kill-window from a binding" -ForegroundColor Yellow
    Key '{F5}'
    $n = Names
    if (($n -notcontains 'keywin') -and ($n -contains 'main')) { Write-Pass "kill-window -t keywin killed keywin only ($($n -join ','))" } else { Write-Fail "kill-window -t keywin -> windows $($n -join ',')" }
    $before = (Names) -join ','
    Key '{F6}'
    $after = (Names) -join ','
    if ($after -eq $before) { Write-Pass "kill-window -t nosuchwin killed nothing" } else { Write-Fail "kill-window -t nosuchwin: '$before' -> '$after'" }

    Write-Host "`n[2] select-window and rename-window from a binding" -ForegroundColor Yellow
    Key '{F7}'
    if ((Current) -eq 'selwin') { Write-Pass "select-window -t selwin" } else { Write-Fail "select-window -t selwin -> current $(Current)" }
    Key '{F8}'
    if ((Current) -eq 'selwin') { Write-Pass "select-window -t nosuchwin left the current window" } else { Write-Fail "select-window -t nosuchwin -> current $(Current)" }
    Key '{F9}'
    $n = Names
    if (($n -contains 'renamed') -and ($n -notcontains 'renwin') -and ($n -contains 'selwin')) { Write-Pass "rename-window -t renwin renamed renwin" } else { Write-Fail "rename-window -t renwin -> $($n -join ',')" }
    $before = (Names) -join ','
    Key '{F10}'
    $after = (Names) -join ','
    if ($after -eq $before) { Write-Pass "rename-window -t nosuchwin renamed nothing" } else { Write-Fail "rename-window -t nosuchwin: '$before' -> '$after'" }

    Write-Host "`n[2b] kill-pane from a binding" -ForegroundColor Yellow
    $cur = Current
    Key '{F3}'
    Start-Sleep -Milliseconds 800
    $n = Names
    if (($n -notcontains 'kpwin') -and ($n -contains $cur)) { Write-Pass "kill-pane -t kpwin closed kpwin's pane only" } else { Write-Fail "kill-pane -t kpwin -> $($n -join ',') (current was $cur)" }
    $before = (Names) -join ','
    Key '{F4}'
    Start-Sleep -Milliseconds 800
    $after = (Names) -join ','
    if ($after -eq $before) { Write-Pass "kill-pane -t nosuchwin killed nothing" } else { Write-Fail "kill-pane -t nosuchwin: '$before' -> '$after'" }

    Write-Host "`n[3] the command prompt" -ForegroundColor Yellow
    Key '^b'; Key ':'; Key 'kill-window -t cpwin{ENTER}'
    $n = Names
    if (($n -notcontains 'cpwin') -and ($n -contains 'selwin')) { Write-Pass "prompt kill-window -t cpwin killed cpwin only" } else { Write-Fail "prompt kill-window -t cpwin -> $($n -join ',')" }
    $before = (Names) -join ','
    Key '^b'; Key ':'; Key 'kill-window -t nosuchwin{ENTER}'
    $after = (Names) -join ','
    if ($after -eq $before) { Write-Pass "prompt kill-window -t nosuchwin killed nothing" } else { Write-Fail "prompt kill-window -t nosuchwin: '$before' -> '$after'" }

    Write-Host "`n[3b] hooks (the in server command path)" -ForegroundColor Yellow
    P new-window -d -t $S -n hookwin | Out-Null
    $cur = Current
    P set-hook -g after-split-window 'kill-window -t hookwin' | Out-Null
    P split-window -t "${S}:$cur" | Out-Null
    Wait-Until { (Names) -notcontains 'hookwin' } 3000 | Out-Null
    $n = Names
    if (($n -notcontains 'hookwin') -and ($n -contains $cur)) { Write-Pass "hook kill-window -t hookwin killed hookwin only" } else { Write-Fail "hook kill-window -t hookwin -> $($n -join ',') (current was $cur)" }
    P set-hook -g after-split-window 'kill-window -t nosuchwin' | Out-Null
    $before = (Names) -join ','
    P split-window -t "${S}:$cur" | Out-Null
    Start-Sleep -Milliseconds 1200
    $after = (Names) -join ','
    if ($after -eq $before) { Write-Pass "hook kill-window -t nosuchwin killed nothing" } else { Write-Fail "hook kill-window -t nosuchwin: '$before' -> '$after'" }
    P set-hook -gu after-split-window | Out-Null

    Write-Host "`n[3c] bindings made with the CLI's bind-key keep their arguments" -ForegroundColor Yellow
    foreach ($n in 'cliwin', 'cliwin2', 'pxwin') { P new-window -d -t $S -n $n | Out-Null }
    Start-Sleep -Milliseconds 800
    $pxpane = ((P display-message -t "${S}:pxwin" -p '#{pane_id}') -join '').Trim()
    P bind -n F2 rename-window -t cliwin clirenamed | Out-Null
    P bind -n F11 kill-window -t :cliwin2 | Out-Null
    P bind x kill-pane -t $pxpane | Out-Null
    $keys = (P list-keys) -join "`n"
    foreach ($want in @('F2 rename-window -t cliwin clirenamed', 'F11 kill-window -t :cliwin2', "x kill-pane -t $pxpane")) {
        if ($keys.Contains($want)) { Write-Pass "list-keys shows '$want'" } else { Write-Fail "list-keys lacks '$want'" }
    }
    $cur = Current
    Key '{F2}'
    $n = Names
    if (($n -contains 'clirenamed') -and ($n -notcontains 'cliwin') -and ($n -contains $cur)) { Write-Pass "F2 renamed cliwin" } else { Write-Fail "F2 -> $($n -join ',') (current $cur)" }
    Key '{F11}'
    $n = Names
    if (($n -notcontains 'cliwin2') -and ($n -contains $cur)) { Write-Pass "F11 killed cliwin2 only" } else { Write-Fail "F11 -> $($n -join ',')" }
    Key '^b'; Key 'x'
    Start-Sleep -Milliseconds 800
    $n = Names
    if (($n -notcontains 'pxwin') -and ($n -contains $cur)) { Write-Pass "prefix x killed pane $pxpane (pxwin) only" } else { Write-Fail "prefix x -> $($n -join ',')" }

    Write-Host "`n[4] a session name is that session's current window" -ForegroundColor Yellow
    P select-window -t "${S}:spare" | Out-Null
    Start-Sleep -Milliseconds 500
    Key '{F12}'
    $n = Names
    if (($n -notcontains 'spare') -and ($n -contains 'main')) { Write-Pass "kill-window -t $S killed the current window (spare)" } else { Write-Fail "kill-window -t $S -> $($n -join ',')" }
} catch {
    Write-Fail "exception: $_"
} finally {
    P kill-server | Out-Null
    if ($tui -and -not $tui.WaitForExit(3000)) { try { Stop-Process -Id $tui.Id -Force } catch {} }
}

Write-Host "`nPassed: $script:TestsPassed  Failed: $script:TestsFailed"
if ($script:TestsFailed -gt 0) { exit 1 } else { Remove-Item -Recurse -Force $work -EA SilentlyContinue; exit 0 }
