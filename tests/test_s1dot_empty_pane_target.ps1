# A target whose pane part is empty: `s:1.`, `=s:two.`, `s:.`, `:1.`, `@2.`.
#
# tmux splits a target at the colon and at the first period after it, then
# reads an empty part as no part at all (cmd-find.c, "Empty is the same as
# NULL"), so `s:1.` is window 1 of s and its active pane. psmux's resolvers
# split the pane off themselves and only when it was non-empty, so `s:1.` was
# looked up as a window NAMED `1.`: display-message, select-window,
# rename-window and send-keys all failed with "can't find window: 1.". A
# choose-tree template (#912) gets exactly that shape for a window row
# (`=s:idx.`, window_tree_get_target), so `choose-tree -Zw "kill-window -t
# '%%'"` could not work.
#
# Every route: the CLI, a raw control connection, source-file, if-shell, a
# hook, join-pane's -s, and choose-tree templates run from a real attached
# client (keys through WriteConsoleInput, tests/injector.cs).
#
# Isolated: -L, and USERPROFILE, PSMUX_DATA_DIR and PSMUX_CONFIG_FILE point
# into a temp dir. PSMUX_EXE picks the binary (defaults to psmux on PATH).

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
foreach ($name in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'PSMUX_*' -and $_.Name -ne 'PSMUX_EXE' -or $_.Name -like 'TMUX*' } | ForEach-Object Name)) {
    Remove-Item "Env:$name"
}
$PSMUX = if ($env:PSMUX_EXE) { $env:PSMUX_EXE } else { (Get-Command psmux -EA Stop).Source }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Pass "$name = '$got'" } else { Write-Fail "$name expected '$want', got '$got'" }
}

$TempHome = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_s1dot_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $TempHome | Out-Null
$env:USERPROFILE = $TempHome
$env:PSMUX_DATA_DIR = $TempHome
. "$PSScriptRoot\isolated_config.ps1" -Lines @(
    "bind R choose-tree -Zw `"rename-window -t '%%' PICKED`"",
    "bind K choose-tree -Zw `"kill-window -t '%%'`""
)
$NS = "s1dot_" + [guid]::NewGuid().ToString('N').Substring(0, 6)
$S = "sd"
function P { & $PSMUX -L $NS @args 2>&1 }
function Names { ((P list-windows -t $S -F '#{window_index}:#{window_name}') -join ' ') }
function Active { ((P display-message -t $S -p '#{window_index}') -join '') }

Write-Host "`n=== Empty pane part in a target (s:1.) ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"

try {
    P new-session -d -s $S -x 120 -y 30 | Out-Null
    Start-Sleep -Seconds 2
    P has-session -t $S | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "session did not start"; exit 1 }
    P set -g allow-rename off | Out-Null
    P set -g automatic-rename off | Out-Null
    P rename-window -t "${S}:0" zero | Out-Null
    P new-window -d -t $S -n two | Out-Null
    P new-window -d -t $S -n three | Out-Null

    Write-Host "`n[1] display-message -t resolves every empty pane form" -ForegroundColor Yellow
    foreach ($case in @(
            @("${S}:1.", "1 two"), @("=${S}:1.", "1 two"), @("${S}:two.", "1 two"),
            @("=${S}:two.", "1 two"), @("${S}:.", "0 zero"), @("${S}:1", "1 two"))) {
        $out = (P display-message -t $case[0] -p '#{window_index} #{window_name}') -join ' '
        Check "display -t $($case[0]) (rc=$LASTEXITCODE)" $out $case[1]
    }
    $wid = ((P display-message -t "${S}:2" -p '#{window_id}') -join '')
    Check "display -t $wid." ((P display-message -t "$wid." -p '#{window_index}') -join '') "2"
    $paneId = ((P display-message -t "${S}:2" -p '#{pane_id}') -join '')
    Check "a non empty pane part still counts, -t ${S}:1.$paneId" ((P display-message -t "${S}:1.$paneId" -p '#{pane_id}') -join '') $paneId

    Write-Host "`n[2] commands from the CLI" -ForegroundColor Yellow
    $out = (P select-window -t "${S}:2.") -join ' '
    Check "select-window -t ${S}:2. rc=$LASTEXITCODE out='$out', active" (Active) "2"
    P select-window -t "${S}:0" | Out-Null
    $out = (P rename-window -t "${S}:1." uno) -join ' '
    Check "rename-window -t ${S}:1. rc=$LASTEXITCODE out='$out', names" (Names) "0:zero 1:uno 2:three"
    P rename-window -t "${S}:1" two | Out-Null
    $out = (P send-keys -t "${S}:three." 'echo S1DOT_KEYS' Enter) -join ' '
    $rc = $LASTEXITCODE
    $seen = $false
    for ($i = 0; $i -lt 20 -and -not $seen; $i++) {
        Start-Sleep -Milliseconds 300
        $seen = ((P capture-pane -t "${S}:2" -p) -join "`n") -match 'S1DOT_KEYS'
    }
    if ($rc -eq 0 -and $seen) { Write-Pass "send-keys -t ${S}:three. reached window 2" } else { Write-Fail "send-keys -t ${S}:three. rc=$rc out='$out' seen=$seen" }
    # Keys that look like a target are not targets: only the flag region is read.
    P send-keys -t "${S}:2" -l "x:y." | Out-Null
    Start-Sleep -Milliseconds 600
    if (((P capture-pane -t "${S}:2" -p) -join "`n") -match 'x:y\.') { Write-Pass "a key 'x:y.' is typed as is" } else { Write-Fail "the key 'x:y.' was changed" }
    P send-keys -t "${S}:2" C-u | Out-Null

    Write-Host "`n[3] a raw control connection" -ForegroundColor Yellow
    $base = "${NS}__$S"
    $port = (Get-Content (Join-Path $TempHome "$base.port") -Raw).Trim()
    $key = (Get-Content (Join-Path $TempHome "$base.key") -Raw).Trim()
    function Tcp($line) {
        $c = [Net.Sockets.TcpClient]::new('127.0.0.1', [int]$port); $c.NoDelay = $true; $c.ReceiveTimeout = 3000
        $st = $c.GetStream(); $w = [IO.StreamWriter]::new($st); $r = [IO.StreamReader]::new($st)
        $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
        $w.Write("$line`n"); $w.Flush()
        $out = try { $r.ReadToEnd() } catch { "<timeout>" }
        $c.Close(); return $out.Trim()
    }
    $out = Tcp "select-window -t :2."
    Check "select-window -t :2. over the socket, reply '$out', active" (Active) "2"
    $out = Tcp "display-message -t :1. -p '#{window_name}'"
    Check "display-message -t :1. over the socket" $out "two"
    P select-window -t "${S}:0" | Out-Null

    Write-Host "`n[4] source-file, if-shell and a hook" -ForegroundColor Yellow
    $conf = Join-Path $TempHome "s1dot.conf"
    Set-Content -Path $conf -Value "rename-window -t ${S}:1. fromconf"
    P source-file $conf | Out-Null
    Check "source-file rename-window -t ${S}:1." (Names) "0:zero 1:fromconf 2:three"
    P if-shell -F 1 "rename-window -t :1. fromif" | Out-Null
    Start-Sleep -Milliseconds 400
    Check "if-shell rename-window -t :1." (Names) "0:zero 1:fromif 2:three"
    P rename-window -t "${S}:1" two | Out-Null
    P set-hook -t $S after-new-window "select-window -t :0." | Out-Null
    P new-window -t $S -n four | Out-Null
    Start-Sleep -Milliseconds 800
    Check "after-new-window hook select-window -t :0., active" (Active) "0"
    P set-hook -u -t $S after-new-window | Out-Null
    P kill-window -t "${S}:four" | Out-Null

    Write-Host "`n[5] join-pane -s takes it too" -ForegroundColor Yellow
    P new-window -d -t $S -n src | Out-Null
    $out = (P join-pane -d -s "${S}:src." -t "${S}:0") -join ' '
    $panes = ((P display-message -t "${S}:0" -p '#{window_panes}') -join '')
    $gone = -not ((Names) -match 'src')
    if ($panes -eq "2" -and $gone) { Write-Pass "join-pane -s ${S}:src. moved its pane into window 0" } else { Write-Fail "join-pane -s ${S}:src. rc=$LASTEXITCODE out='$out' panes=$panes names='$(Names)'" }
    P kill-pane -t "${S}:0.1" | Out-Null

    Write-Host "`n[6] choose-tree templates from a window row (live client)" -ForegroundColor Yellow
    $toolDir = Join-Path $TempHome "tools"
    New-Item -ItemType Directory -Force $toolDir | Out-Null
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
    $INJ = Join-Path $toolDir "injector.exe"
    & $csc /nologo /optimize /out:$INJ (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
    if (-not (Test-Path $INJ)) { Write-Fail "injector did not compile" }
    else {
        P select-window -t "${S}:0" | Out-Null
        $c = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NS, "attach", "-t", $S -PassThru
        Start-Sleep -Seconds 4
        # Rows (windows collapsed): sd, sd:0 (cursor), sd:1, sd:2.
        & $INJ $c.Id "^b{SLEEP:500}R{SLEEP:1500}{DOWN}{SLEEP:400}{ENTER}" | Out-Null
        Start-Sleep -Milliseconds 1500
        Check "choose-tree -Zw `"rename-window -t '%%' PICKED`" on sd:1" (Names) "0:zero 1:PICKED 2:three"
        & $INJ $c.Id "^b{SLEEP:500}K{SLEEP:1500}{DOWN}{SLEEP:300}{DOWN}{SLEEP:400}{ENTER}" | Out-Null
        Start-Sleep -Milliseconds 1500
        Check "choose-tree -Zw `"kill-window -t '%%'`" on sd:2" (Names) "0:zero 1:PICKED"
        $alive = -not (Get-Process -Id $c.Id -EA SilentlyContinue).HasExited
        if ($alive) { Write-Pass "the client is still attached" } else { Write-Fail "the client went away" }
        try { Stop-Process -Id $c.Id -Force -EA SilentlyContinue } catch {}
        Start-Sleep -Milliseconds 700
    }
}
finally {
    P kill-server | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-PsmuxIsolatedConfig
    Remove-Item -Recurse -Force $TempHome -EA SilentlyContinue
}

Write-Host "`n=== Results: $script:TestsPassed passed, $script:TestsFailed failed ===" -ForegroundColor $(if ($script:TestsFailed -eq 0) { 'Green' } else { 'Yellow' })
exit $script:TestsFailed
