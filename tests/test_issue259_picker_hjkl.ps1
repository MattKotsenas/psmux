# Issue #259: hjkl navigation parity in pickers (matches tmux mode-tree)
#
# tmux's mode-tree (used by choose-tree, choose-buffer, choose-client,
# customize-mode) accepts h/k = up and j/l = down for flat lists, plus
# g/G as Home/End. Before this fix psmux only accepted Up/Down arrows in
# the session picker (C-b s) and tree picker (C-b w), and only j/k in the
# buffer picker (C-b =). This test proves all four hjkl keys plus g/G now
# navigate every picker.
#
# This test combines:
#   PART 1 — Source-code proof: every picker has KeyCode::Char('h'/'j'/'k'/'l')
#            handlers wired to the up/down navigation logic.
#   PART 2 — Live behavioral proof: launch a real attached psmux client,
#            inject hjkl keystrokes via WriteConsoleInput into the session
#            picker, and verify the client actually switched sessions
#            (proven by querying each session's session-info over TCP and
#            checking which one has "(attached)").

$ErrorActionPreference = "Continue"
$script:pass = 0
$script:fail = 0
$script:results = @()

function Write-Test($msg) { Write-Host "  TEST: $msg" -ForegroundColor Yellow }
function Write-Pass($msg) { Write-Host "  PASS: $msg" -ForegroundColor Green; $script:pass++ }
function Write-Fail($msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:fail++ }
function Add-Result($name, $ok, $detail) {
    if ($ok) { Write-Pass "$name $detail" } else { Write-Fail "$name $detail" }
    $script:results += [PSCustomObject]@{ Test = $name; Pass = $ok; Detail = $detail }
}

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -EA SilentlyContinue).Path
if (-not $PSMUX) {
    $cmd = Get-Command psmux -EA SilentlyContinue
    if ($cmd) { $PSMUX = $cmd.Source }
}
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$psmuxDir = "$env:USERPROFILE\.psmux"
$env:PSMUX_SESSION = ""

Write-Host "`n=== Issue #259: hjkl picker navigation ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"

# ════════════════════════════════════════════════════════════════════
# PART 1 — Source-code proof
# ════════════════════════════════════════════════════════════════════

$srcFile = Join-Path $PSScriptRoot "..\src\client.rs"
$src = Get-Content $srcFile -Raw

# --- session_chooser ---
Write-Test "session_chooser: KeyCode::Char('k') decrements session_selected"
$sc_k = $src -match "KeyCode::Char\('k'\)\s+if\s+session_chooser\s*=>\s*\{\s*if\s+session_selected\s*>\s*0\s*\{\s*session_selected\s*-=\s*1"
Add-Result "session_chooser k -> up" $sc_k ""

Write-Test "session_chooser: KeyCode::Char('j') increments session_selected"
# Post-ea71e75 down-navigation is bounded by the filtered list length
# (session_filtered_indices), not raw session_entries.
$sc_j = $src -match "KeyCode::Char\('j'\)\s+if\s+session_chooser\s*=>\s*\{\s*let\s+visible_len\s*=\s*session_filtered_indices\(&session_entries,\s*&session_filter\)\.len\(\);\s*if\s+session_selected\s*\+\s*1\s*<\s*visible_len\s*\{\s*session_selected\s*\+=\s*1"
Add-Result "session_chooser j -> down" $sc_j ""

Write-Test "session_chooser: KeyCode::Char('h') navigates up (tmux mode-tree parity)"
$sc_h = $src -match "KeyCode::Char\('h'\)\s+if\s+session_chooser\s*=>\s*\{\s*if\s+session_selected\s*>\s*0"
Add-Result "session_chooser h -> up" $sc_h ""

Write-Test "session_chooser: KeyCode::Char('l') navigates down (tmux mode-tree parity)"
$sc_l = $src -match "KeyCode::Char\('l'\)\s+if\s+session_chooser\s*=>\s*\{\s*let\s+visible_len\s*=\s*session_filtered_indices\(&session_entries,\s*&session_filter\)\.len\(\);\s*if\s+session_selected\s*\+\s*1\s*<\s*visible_len\s*\{\s*session_selected\s*\+=\s*1"
Add-Result "session_chooser l -> down" $sc_l ""

Write-Test "session_chooser: g/G map to Home/End"
# NOTE: PowerShell variable names are case-insensitive, so $sc_g and $sc_G
# were the SAME variable and the "g -> top" check silently reported the G
# result. Distinct names keep both checks real. G is bounded by the filtered
# list (session_filtered_indices) post-ea71e75.
$sc_g_top = $src -match "KeyCode::Char\('g'\)\s+if\s+session_chooser\s*=>\s*\{\s*session_selected\s*=\s*0"
$sc_G_bottom = $src -match "KeyCode::Char\('G'\)\s+if\s+session_chooser\s*=>\s*\{\s*session_selected\s*=\s*session_filtered_indices\(&session_entries,\s*&session_filter\)\.len\(\)\.saturating_sub\(1\)"
Add-Result "session_chooser g -> top" $sc_g_top ""
Add-Result "session_chooser G -> bottom" $sc_G_bottom ""

# --- tree_chooser ---
Write-Test "tree_chooser: KeyCode::Char('k') decrements tree_selected"
$tc_k = $src -match "KeyCode::Char\('k'\)\s+if\s+tree_chooser\s*=>\s*\{\s*if\s+tree_selected\s*>\s*0\s*\{\s*tree_selected\s*-=\s*1"
Add-Result "tree_chooser k -> up" $tc_k ""

Write-Test "tree_chooser: KeyCode::Char('j') increments tree_selected"
$tc_j = $src -match "KeyCode::Char\('j'\)\s+if\s+tree_chooser\s*=>\s*\{\s*if\s+tree_selected\s*\+\s*1\s*<\s*tree_entries\.len"
Add-Result "tree_chooser j -> down" $tc_j ""

# The tree's rows have depth, so tmux's mode_tree_key gives h/- the Left arm
# (collapse, or go to the parent) and l/+ the Right arm (expand, or move down
# once expanded), mode-tree.c `case KEYC_LEFT: case 'h': case '-':`. Since
# discussion 776 psmux routes them through choose_tree::mode_tree_alias; the
# behaviour itself is driven key by key in tests/test_disc776_chooser_parity.ps1.
$treeSrc = Get-Content (Join-Path (Split-Path $srcFile) "choose_tree.rs") -Raw
Write-Test "tree_chooser: h and - collapse like tmux's KEYC_LEFT arm"
$tc_h = $treeSrc -match "KeyCode::Char\('h'\)\s*\|\s*KeyCode::Char\('-'\)\s+if\s+plain\s*&&\s*tree\s*=>\s*Some\(ModeKey::Collapse\)"
Add-Result "tree_chooser h -> collapse (tmux)" $tc_h ""

Write-Test "tree_chooser: l and + expand like tmux's KEYC_RIGHT arm"
$tc_l = $treeSrc -match "KeyCode::Char\('l'\)\s*\|\s*KeyCode::Char\('\+'\)\s+if\s+plain\s*&&\s*tree\s*=>\s*Some\(ModeKey::Expand\)"
Add-Result "tree_chooser l -> expand (tmux)" $tc_l ""

Write-Test "tree_chooser: g/G map to Home/End"
# Distinct names: $tc_g/$tc_G collide (PS vars are case-insensitive).
$tc_g_top = $src -match "KeyCode::Char\('g'\)\s+if\s+tree_chooser\s*=>\s*\{\s*tree_selected\s*=\s*0"
$tc_G_bottom = $src -match "KeyCode::Char\('G'\)\s+if\s+tree_chooser\s*=>\s*\{\s*tree_selected\s*=\s*tree_entries\.len\(\)\.saturating_sub\(1\)"
Add-Result "tree_chooser g -> top" $tc_g_top ""
Add-Result "tree_chooser G -> bottom" $tc_G_bottom ""

# --- buffer_chooser ---
Write-Test "buffer_chooser: existing j/k still wired"
$bc_jk = $src -match "KeyCode::Up\s*\|\s*KeyCode::Char\('k'\)\s+if\s+buffer_chooser" -and `
         $src -match "KeyCode::Down\s*\|\s*KeyCode::Char\('j'\)\s+if\s+buffer_chooser"
Add-Result "buffer_chooser j/k present" $bc_jk ""

Write-Test "buffer_chooser: KeyCode::Char('h') navigates up"
$bc_h = $src -match "KeyCode::Char\('h'\)\s+if\s+buffer_chooser\s*=>\s*\{\s*if\s+buffer_selected\s*>\s*0"
Add-Result "buffer_chooser h -> up" $bc_h ""

Write-Test "buffer_chooser: KeyCode::Char('l') navigates down"
$bc_l = $src -match "KeyCode::Char\('l'\)\s+if\s+buffer_chooser\s*=>\s*\{\s*if\s+buffer_selected\s*\+\s*1\s*<\s*buffer_entries\.len"
Add-Result "buffer_chooser l -> down" $bc_l ""

Write-Test "buffer_chooser: g/G map to Home/End"
# Distinct names: $bc_g/$bc_G collide (PS vars are case-insensitive).
$bc_g_top = $src -match "KeyCode::Char\('g'\)\s+if\s+buffer_chooser\s*=>\s*\{\s*buffer_selected\s*=\s*0"
$bc_G_bottom = $src -match "KeyCode::Char\('G'\)\s+if\s+buffer_chooser\s*=>\s*\{\s*buffer_selected\s*=\s*buffer_entries\.len\(\)\.saturating_sub\(1\)"
Add-Result "buffer_chooser g -> top" $bc_g_top ""
Add-Result "buffer_chooser G -> bottom" $bc_G_bottom ""

# --- keys_viewer ---
Write-Test "keys_viewer: hjkl all wired"
$kv_h = $src -match "KeyCode::Char\('h'\)\s+if\s+keys_viewer"
$kv_l = $src -match "KeyCode::Char\('l'\)\s+if\s+keys_viewer"
Add-Result "keys_viewer h" $kv_h ""
Add-Result "keys_viewer l" $kv_l ""

# --- customize ---
Write-Test "srv_customize: hjkl all wired (server-side customize-navigate)"
$cu_h = $src -match "KeyCode::Char\('h'\)\s*=>\s*\{\s*cmd_batch\.push\(""customize-navigate -1"
$cu_l = $src -match "KeyCode::Char\('l'\)\s*=>\s*\{\s*cmd_batch\.push\(""customize-navigate 1"
Add-Result "customize h -> nav -1" $cu_h ""
Add-Result "customize l -> nav 1" $cu_l ""

# ════════════════════════════════════════════════════════════════════
# PART 2 — Live behavioral proof via WriteConsoleInput
# ════════════════════════════════════════════════════════════════════
#
# Launch an attached psmux client, open the session picker with C-b s,
# press j (down) and Enter, then prove the client switched to the next
# session by checking which session reports "(attached)" via session-info.

$injectorExe = "$env:TEMP\psmux_injector.exe"
$injectorSrc = Join-Path $PSScriptRoot "injector.cs"
if (-not (Test-Path $injectorExe) -or ((Get-Item $injectorSrc).LastWriteTime -gt (Get-Item $injectorExe).LastWriteTime)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    & $csc /nologo /optimize /out:$injectorExe $injectorSrc 2>&1 | Out-Null
}
$haveInjector = Test-Path $injectorExe
Add-Result "injector compiled" $haveInjector $injectorExe

# Use names that sort alphabetically: a_259, b_259, c_259, d_259.
# Picker is alphabetical, so attaching to a_259 puts cursor at index 0;
# pressing j once moves to b_259.
$S1 = "a_issue259"; $S2 = "b_issue259"; $S3 = "c_issue259"; $S4 = "d_issue259"
foreach ($s in @($S1,$S2,$S3,$S4)) { & $PSMUX kill-session -t $s 2>$null | Out-Null }
Start-Sleep -Milliseconds 500

foreach ($s in @($S1,$S2,$S3,$S4)) {
    & $PSMUX new-session -d -s $s 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
}

function Wait-Session($name, [int]$timeoutSec = 8) {
    for ($i = 0; $i -lt ($timeoutSec * 4); $i++) {
        & $PSMUX has-session -t $name 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
$alive = (Wait-Session $S1) -and (Wait-Session $S2) -and (Wait-Session $S3) -and (Wait-Session $S4)
Add-Result "four test sessions started" $alive ""

function Query-Attached($name) {
    $pf = "$psmuxDir\$name.port"
    $kf = "$psmuxDir\$name.key"
    if (-not (Test-Path $pf)) { return $null }
    try {
        $port = [int]((Get-Content $pf -Raw).Trim())
        $key  = if (Test-Path $kf) { (Get-Content $kf -Raw).Trim() } else { "" }
        $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
        $st   = $tcp.GetStream()
        $st.ReadTimeout = 2000
        $w    = [System.IO.StreamWriter]::new($st); $w.AutoFlush = $true
        $r    = [System.IO.StreamReader]::new($st)
        $w.WriteLine("AUTH $key"); $null = $r.ReadLine()
        $w.WriteLine("session-info")
        $line = $r.ReadLine()
        $tcp.Close()
        return $line
    } catch { return $null }
}

function Test-NavViaInjection {
    param(
        [string]$NavKey,        # 'j' | 'k' | 'h' | 'l' | 'g' | 'G'
        [string]$StartSession,  # session to attach to first
        [string]$ExpectSession  # session we expect to be attached to after navigation
    )
    Write-Host ""
    Write-Test "Live: attach to $StartSession, prefix+s + '$NavKey' + Enter -> switch to $ExpectSession"

    # Launch a fresh visible client attached to the start session.
    $proc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$StartSession -PassThru
    Start-Sleep -Seconds 4

    # Confirm the start session has the (attached) marker before injecting.
    $infoStart = Query-Attached $StartSession
    $startedAttached = $infoStart -match "\(attached\)"
    if (-not $startedAttached) {
        Add-Result "$NavKey live: pre-condition (start session attached)" $false "info=$infoStart"
        try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
        return
    }

    # Inject:  Ctrl+B  pause  s  pause  <NavKey>  pause  Enter
    & $injectorExe $proc.Id "^b{SLEEP:400}s{SLEEP:600}$NavKey{SLEEP:300}{ENTER}" | Out-Null

    # The PSMUX_SWITCH_TO handshake needs a moment to detach + reconnect
    # (client-detach on the old server, then run_remote re-attaches to the
    # new one). A single point-in-time check after a fixed sleep is flaky
    # under system load (observed: both origin and target briefly showing
    # detached mid-handshake) -- poll for up to 8s instead of a one-shot
    # check at 4s, matching the Wait-Session retry pattern used elsewhere
    # in this file for the same class of async-completion race.
    $infoExpect = $null
    $infoStartAfter = $null
    $switched = $false
    for ($i = 0; $i -lt 16; $i++) {
        Start-Sleep -Milliseconds 500
        $infoExpect = Query-Attached $ExpectSession
        $infoStartAfter = Query-Attached $StartSession
        $switched = ($infoExpect -match "\(attached\)") -and -not ($infoStartAfter -match "\(attached\)")
        if ($switched) { break }
    }

    Add-Result "$NavKey live: client moved $StartSession -> $ExpectSession" $switched ("after: target=`"$infoExpect`" origin=`"$infoStartAfter`"")

    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Start-Sleep -Seconds 1
}

if ($haveInjector -and $alive) {
    # j moves cursor down by 1 -> a -> b
    Test-NavViaInjection -NavKey 'j' -StartSession $S1 -ExpectSession $S2
    # l also moves down -> a -> b
    Test-NavViaInjection -NavKey 'l' -StartSession $S1 -ExpectSession $S2
    # k moves up by 1 from b -> a
    Test-NavViaInjection -NavKey 'k' -StartSession $S2 -ExpectSession $S1
    # h also moves up -> b -> a
    Test-NavViaInjection -NavKey 'h' -StartSession $S2 -ExpectSession $S1
    # G jumps to last (d_issue259)
    Test-NavViaInjection -NavKey 'G' -StartSession $S1 -ExpectSession $S4
    # g jumps to first (a_issue259) from d
    Test-NavViaInjection -NavKey 'g' -StartSession $S4 -ExpectSession $S1
} else {
    Add-Result "live behavioral tests" $false "skipped (injector or sessions missing)"
}

# ════════════════════════════════════════════════════════════════════
# Cleanup
# ════════════════════════════════════════════════════════════════════
foreach ($s in @($S1,$S2,$S3,$S4)) { & $PSMUX kill-session -t $s 2>$null | Out-Null }

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass / $($pass + $fail)" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
foreach ($r in $results) {
    $color  = if ($r.Pass) { 'Green' } else { 'Red' }
    $status = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "  [$status] $($r.Test) $($r.Detail)" -ForegroundColor $color
}

exit $fail
