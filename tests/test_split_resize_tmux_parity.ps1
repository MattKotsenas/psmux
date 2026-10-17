# split-window / join-pane / resize-pane / kill-pane geometry against tmux 3.4.
#
# Every expected line below is tmux 3.4's own output (WSL Ubuntu,
# `tmux -L tanaesplit -f /dev/null new-session -d -x X -y Y`, then the case's
# commands), read back as `#{pane_index}:<creation rank>:#{pane_left},#{pane_top}:
# #{pane_width}x#{pane_height}:#{pane_active}` plus `#{window_layout}` with the
# checksum and pane ids blanked (they differ between the two programs).
#
# What this pins (all measured wrong on master 652d08b4 before the fix):
#   * split sizes in cells, tmux layout_split_sizes: 120 -> 60 | 59, 30 -> 15 / 14
#     (psmux gave 59 | 60 and 14 / 15), -l N and -l N% of the PANE
#   * resize-pane in cells, tmux layout_resize_pane: -R 1 three times is
#     61, 62, 63 (psmux 60, 61, 63), -D 1 three times on 30 rows moves 3
#     (psmux 0), -y 10 is 10 rows (psmux 2)
#   * a split the same way as its parent joins the parent, as tmux does
#     ({60,29,29}, psmux nested {59,{29,30}})
#   * a killed pane's cells go to its neighbour (tmux layout_destroy_cell),
#     psmux equalised the survivors
#   * split-window -b and -f (psmux ignored both), and join-pane -b sizes
#
# Not compared here, on purpose: a pane pushed to the minimum (psmux keeps two
# columns, MIN_PTY_COLS, where tmux allows one), and select-layout (see the
# layout suites).
#
# Binary: $env:PSMUX_BIN if set, else psmux on PATH. Own -L namespace;
# honours PSMUX_DATA_DIR. Set PSMUX_PARITY_ONLY to a regex to run some cases.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_BIN) { $env:PSMUX_BIN } elseif ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = "splitparity" + (Get-Random -Maximum 99999)
$script:Pass = 0; $script:Fail = 0
$env:PSMUX_RUN_NOPAUSE = '1'
$env:PSMUX_NO_WARM = '1'
foreach ($v in 'PSMUX_SESSION','PSMUX_SESSION_NAME','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') { Remove-Item "env:$v" -EA SilentlyContinue }
Write-Host "binary: $PSMUX  namespace: $NS" -ForegroundColor Cyan
function P { & $PSMUX -L $NS @args 2>&1 }

# name | x | y | commands (;; separated, CMD = a command for the new pane) | tmux layout | tmux panes
$cases = @(
    ,@('h', 120, 30, 'split-window -h', 'f09b,120x30,0,0{60x30,0,0,0,59x30,61,0,1}', '0:0:0,0:60x30:0 1:1:61,0:59x30:1')
    ,@('v', 120, 30, 'split-window -v', 'e9aa,120x30,0,0[120x15,0,0,0,120x14,0,16,1]', '0:0:0,0:120x15:0 1:1:0,16:120x14:1')
    ,@('hb', 120, 30, 'split-window -h -b', '709f,120x30,0,0{60x30,0,0,1,59x30,61,0,0}', '0:1:0,0:60x30:1 1:0:61,0:59x30:0')
    ,@('vb', 120, 30, 'split-window -v -b', '69ac,120x30,0,0[120x15,0,0,1,120x14,0,16,0]', '0:1:0,0:120x15:1 1:0:0,16:120x14:0')
    ,@('hb_cmd', 120, 30, 'split-window -h -b CMD', '709f,120x30,0,0{60x30,0,0,1,59x30,61,0,0}', '0:1:0,0:60x30:1 1:0:61,0:59x30:0')
    ,@('vb_cmd', 120, 30, 'split-window -v -b CMD', '69ac,120x30,0,0[120x15,0,0,1,120x14,0,16,0]', '0:1:0,0:120x15:1 1:0:0,16:120x14:0')
    ,@('hbd', 120, 30, 'split-window -h -b -d', '709f,120x30,0,0{60x30,0,0,1,59x30,61,0,0}', '0:1:0,0:60x30:0 1:0:61,0:59x30:1')
    ,@('h_then_sel0_vb', 120, 30, 'split-window -h;;select-pane -t 0;;split-window -v -b', 'deae,120x30,0,0{60x30,0,0[60x15,0,0,2,60x14,0,16,0],59x30,61,0,1}', '0:2:0,0:60x15:1 1:0:0,16:60x14:0 2:1:61,0:59x30:0')
    ,@('h_then_sel1_hb', 120, 30, 'split-window -h;;select-pane -t 1;;split-window -h -b', 'f747,120x30,0,0{60x30,0,0,0,29x30,61,0,2,29x30,91,0,1}', '0:0:0,0:60x30:0 1:2:61,0:29x30:1 2:1:91,0:29x30:0')
    ,@('h_then_vb_on1', 120, 30, 'split-window -h;;split-window -v -b', '8523,120x30,0,0{60x30,0,0,0,59x30,61,0[59x15,61,0,2,59x14,61,16,1]}', '0:0:0,0:60x30:0 1:2:61,0:59x15:1 2:1:61,16:59x14:0')
    ,@('h_then_fhb', 120, 30, 'split-window -h;;split-window -f -h -b', 'f77f,120x30,0,0{60x30,0,0,2,29x30,61,0,0,29x30,91,0,1}', '0:2:0,0:60x30:1 1:0:61,0:29x30:0 2:1:91,0:29x30:0')
    ,@('h_then_fvb', 120, 30, 'split-window -h;;split-window -f -v -b', '6fb1,120x30,0,0[120x15,0,0,2,120x14,0,16{60x14,0,16,0,59x14,61,16,1}]', '0:2:0,0:120x15:1 1:0:0,16:60x14:0 2:1:61,16:59x14:0')
    ,@('h_then_fv', 120, 30, 'split-window -h;;split-window -f -v', '71f7,120x30,0,0[120x15,0,0{60x15,0,0,0,59x15,61,0,1},120x14,0,16,2]', '0:0:0,0:60x15:0 1:1:61,0:59x15:0 2:2:0,16:120x14:1')
    ,@('v_then_fh', 120, 30, 'split-window -v;;split-window -f -h', '5e91,120x30,0,0{60x30,0,0[60x15,0,0,0,60x14,0,16,1],59x30,61,0,2}', '0:0:0,0:60x15:0 1:1:0,16:60x14:0 2:2:61,0:59x30:1')
    ,@('l30_h', 120, 30, 'split-window -h -l 30', '075c,120x30,0,0{89x30,0,0,0,30x30,90,0,1}', '0:0:0,0:89x30:0 1:1:90,0:30x30:1')
    ,@('l30p_h', 120, 30, 'split-window -h -l 30%', '181c,120x30,0,0{83x30,0,0,0,36x30,84,0,1}', '0:0:0,0:83x30:0 1:1:84,0:36x30:1')
    ,@('l10_vb', 120, 30, 'split-window -v -b -l 10', 'a6ab,120x30,0,0[120x10,0,0,1,120x19,0,11,0]', '0:1:0,0:120x10:1 1:0:0,11:120x19:0')
    ,@('l25p_v', 120, 30, 'split-window -v -l 25%', '30c8,120x30,0,0[120x22,0,0,0,120x7,0,23,1]', '0:0:0,0:120x22:0 1:1:0,23:120x7:1')
    ,@('l30_hb', 120, 30, 'split-window -h -b -l 30', '61cf,120x30,0,0{30x30,0,0,1,89x30,31,0,0}', '0:1:0,0:30x30:1 1:0:31,0:89x30:0')
    ,@('odd_h', 121, 31, 'split-window -h', '0090,121x31,0,0{60x31,0,0,0,60x31,61,0,1}', '0:0:0,0:60x31:0 1:1:61,0:60x31:1')
    ,@('odd_v', 121, 31, 'split-window -v', '0bcc,121x31,0,0[121x15,0,0,0,121x15,0,16,1]', '0:0:0,0:121x15:0 1:1:0,16:121x15:1')
    ,@('odd_hb', 121, 31, 'split-window -h -b', '8093,121x31,0,0{60x31,0,0,1,60x31,61,0,0}', '0:1:0,0:60x31:1 1:0:61,0:60x31:0')
    ,@('even_v', 120, 31, 'split-window -v', 'eaab,120x31,0,0[120x15,0,0,0,120x15,0,16,1]', '0:0:0,0:120x15:0 1:1:0,16:120x15:1')
    ,@('three_h', 120, 30, 'split-window -h;;split-window -h', '7744,120x30,0,0{60x30,0,0,0,29x30,61,0,1,29x30,91,0,2}', '0:0:0,0:60x30:0 1:1:61,0:29x30:0 2:2:91,0:29x30:1')
    ,@('three_h_sel0', 120, 30, 'split-window -h;;select-pane -t 0;;split-window -h', '7377,120x30,0,0{30x30,0,0,0,29x30,31,0,2,59x30,61,0,1}', '0:0:0,0:30x30:0 1:2:31,0:29x30:1 2:1:61,0:59x30:0')
    ,@('four_tiled', 120, 30, 'split-window -h;;split-window -v;;select-pane -t 0;;split-window -v', '435e,120x30,0,0{60x30,0,0[60x15,0,0,0,60x14,0,16,3],59x30,61,0[59x15,61,0,1,59x14,61,16,2]}', '0:0:0,0:60x15:0 1:3:0,16:60x14:1 2:1:61,0:59x15:0 3:2:61,16:59x14:0')
    ,@('resR', 120, 30, 'split-window -h;;resize-pane -t 0 -R 1', 'fa7b,120x30,0,0{61x30,0,0,0,58x30,62,0,1}', '0:0:0,0:61x30:0 1:1:62,0:58x30:1')
    ,@('resR2', 120, 30, 'split-window -h;;resize-pane -t 0 -R 1;;resize-pane -t 0 -R 1', '045c,120x30,0,0{62x30,0,0,0,57x30,63,0,1}', '0:0:0,0:62x30:0 1:1:63,0:57x30:1')
    ,@('resR3', 120, 30, 'split-window -h;;resize-pane -t 0 -R 1;;resize-pane -t 0 -R 1;;resize-pane -t 0 -R 1', '0e3c,120x30,0,0{63x30,0,0,0,56x30,64,0,1}', '0:0:0,0:63x30:0 1:1:64,0:56x30:1')
    ,@('resR6', 120, 30, 'split-window -h;;resize-pane -t 0 -R 6', '2bdc,120x30,0,0{66x30,0,0,0,53x30,67,0,1}', '0:0:0,0:66x30:0 1:1:67,0:53x30:1')
    ,@('resL3', 120, 30, 'split-window -h;;resize-pane -t 0 -L 1;;resize-pane -t 0 -L 1;;resize-pane -t 0 -L 1', '30cc,120x30,0,0{57x30,0,0,0,62x30,58,0,1}', '0:0:0,0:57x30:0 1:1:58,0:62x30:1')
    ,@('resR_on1', 120, 30, 'split-window -h;;resize-pane -t 1 -R 1;;resize-pane -t 1 -R 1;;resize-pane -t 1 -R 1', '0e3c,120x30,0,0{63x30,0,0,0,56x30,64,0,1}', '0:0:0,0:63x30:0 1:1:64,0:56x30:1')
    ,@('resL_on1', 120, 30, 'split-window -h;;resize-pane -t 1 -L 1;;resize-pane -t 1 -L 1;;resize-pane -t 1 -L 1', '30cc,120x30,0,0{57x30,0,0,0,62x30,58,0,1}', '0:0:0,0:57x30:0 1:1:58,0:62x30:1')
    ,@('resD3', 120, 30, 'split-window -v;;resize-pane -t 0 -D 1;;resize-pane -t 0 -D 1;;resize-pane -t 0 -D 1', '5eab,120x30,0,0[120x18,0,0,0,120x11,0,19,1]', '0:0:0,0:120x18:0 1:1:0,19:120x11:1')
    ,@('resU3', 120, 30, 'split-window -v;;resize-pane -t 0 -U 1;;resize-pane -t 0 -U 1;;resize-pane -t 0 -U 1', '74aa,120x30,0,0[120x12,0,0,0,120x17,0,13,1]', '0:0:0,0:120x12:0 1:1:0,13:120x17:1')
    ,@('resx', 120, 30, 'split-window -h;;resize-pane -t 0 -x 40', 'e6bb,120x30,0,0{40x30,0,0,0,79x30,41,0,1}', '0:0:0,0:40x30:0 1:1:41,0:79x30:1')
    ,@('resy', 120, 30, 'split-window -v;;resize-pane -t 0 -y 10', '26aa,120x30,0,0[120x10,0,0,0,120x19,0,11,1]', '0:0:0,0:120x10:0 1:1:0,11:120x19:1')
    ,@('res3R', 120, 30, 'split-window -h;;split-window -h;;resize-pane -t 0 -R 1;;resize-pane -t 0 -R 1;;resize-pane -t 0 -R 1', '6445,120x30,0,0{63x30,0,0,0,26x30,64,0,1,29x30,91,0,2}', '0:0:0,0:63x30:0 1:1:64,0:26x30:0 2:2:91,0:29x30:1')
    ,@('join_hb', 120, 30, 'new-window -d;;join-pane -h -b -s :1 -t :0', '709f,120x30,0,0{60x30,0,0,1,59x30,61,0,0}', '0:1:0,0:60x30:1 1:0:61,0:59x30:0')
    ,@('join_vb', 120, 30, 'new-window -d;;join-pane -v -b -s :1 -t :0', '69ac,120x30,0,0[120x15,0,0,1,120x14,0,16,0]', '0:1:0,0:120x15:1 1:0:0,16:120x14:0')
    ,@('join_h', 120, 30, 'new-window -d;;join-pane -h -s :1 -t :0', 'f09b,120x30,0,0{60x30,0,0,0,59x30,61,0,1}', '0:0:0,0:60x30:0 1:1:61,0:59x30:1')
    ,@('kill_mid3', 120, 30, 'split-window -h;;split-window -h;;kill-pane -t 1', '7f6c,120x30,0,0{90x30,0,0,0,29x30,91,0,2}', '0:0:0,0:90x30:0 1:1:91,0:29x30:1')
    ,@('kill_first3', 120, 30, 'split-window -h;;split-window -h;;kill-pane -t 0', '7f70,120x30,0,0{90x30,0,0,1,29x30,91,0,2}', '0:0:0,0:90x30:0 1:1:91,0:29x30:1')
    ,@('kill_last3', 120, 30, 'split-window -h;;split-window -h;;kill-pane -t 2', 'f09b,120x30,0,0{60x30,0,0,0,59x30,61,0,1}', '0:0:0,0:60x30:0 1:1:61,0:59x30:1')
    ,@('kill_tiled', 120, 30, 'split-window -h;;split-window -v;;select-pane -t 0;;split-window -v;;kill-pane -t 1', 'c522,120x30,0,0{60x30,0,0,0,59x30,61,0[59x15,61,0,1,59x14,61,16,2]}', '0:0:0,0:60x30:1 1:1:61,0:59x15:0 2:2:61,16:59x14:0')
    ,@('resR_nested', 120, 30, 'split-window -h;;split-window -v;;resize-pane -t 1 -R 1;;resize-pane -t 1 -R 1', 'd897,120x30,0,0{62x30,0,0,0,57x30,63,0[57x15,63,0,1,57x14,63,16,2]}', '0:0:0,0:62x30:0 1:1:63,0:57x15:0 2:2:63,16:57x14:1')
    ,@('resL_nested', 120, 30, 'split-window -h;;split-window -v;;resize-pane -t 2 -L 5', '30ea,120x30,0,0{55x30,0,0,0,64x30,56,0[64x15,56,0,1,64x14,56,16,2]}', '0:0:0,0:55x30:0 1:1:56,0:64x15:0 2:2:56,16:64x14:1')
    ,@('resD_nested', 120, 30, 'split-window -h;;split-window -v;;resize-pane -t 1 -D 2', 'e8a2,120x30,0,0{60x30,0,0,0,59x30,61,0[59x17,61,0,1,59x12,61,18,2]}', '0:0:0,0:60x30:0 1:1:61,0:59x17:0 2:2:61,18:59x12:1')
    ,@('resU_on_last', 120, 30, 'split-window -v;;split-window -v;;resize-pane -t 2 -U 3', '6f9a,120x30,0,0[120x15,0,0,0,120x4,0,16,1,120x9,0,21,2]', '0:0:0,0:120x15:0 1:1:0,16:120x4:0 2:2:0,21:120x9:1')
    ,@('hb_cluster', 120, 30, 'split-window -hb', '709f,120x30,0,0{60x30,0,0,1,59x30,61,0,0}', '0:1:0,0:60x30:1 1:0:61,0:59x30:0')
)

function Strip-Layout([string]$l) {
    $l = $l -replace '^[0-9a-f]{4},', ''
    ($l -replace ',(\d+)([\]\},])', ',P$2') -replace ',(\d+)$', ',P'
}

foreach ($c in $cases) {
    if ($null -eq $c) { continue }
    $name, $x, $y, $cmds, $wantLayout, $wantPanes = $c
    if ($env:PSMUX_PARITY_ONLY -and $name -notmatch $env:PSMUX_PARITY_ONLY) { continue }
    $s = "c" + (Get-Random -Maximum 99999)
    P new-session -d -s $s -x $x -y $y | Out-Null
    foreach ($cmd in ($cmds -split ';;')) {
        $w = @($cmd.Trim() -split '\s+' | ForEach-Object { if ($_ -eq 'CMD') { 'cmd'; '/k'; 'rem' } else { $_ } })
        for ($i = 0; $i -lt $w.Count; $i++) {
            if ($w[$i] -eq '-t' -and $w[$i+1] -match '^\d$') { $w[$i+1] = "${s}:." + $w[$i+1] }
            if ($w[$i] -eq '-s' -and $w[$i+1] -eq ':1') { $w[$i+1] = "${s}:1" }
            if ($w[$i] -eq '-t' -and $w[$i+1] -eq ':0') { $w[$i+1] = "${s}:0" }
        }
        if ($w[0] -eq 'new-window') { $w += @('-t', "${s}:1") }
        elseif ($w -notcontains '-t') { $w = @($w[0], '-t', $s) + @($w | Select-Object -Skip 1) }
        P @w | Out-Null
        Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Milliseconds 300
    $lay = Strip-Layout ((P display-message -p -t "${s}:0" '#{window_layout}') | Out-String).Trim()
    $rows = @((P list-panes -t "${s}:0" -F '#{pane_index} #{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_active}') | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+ %' })
    $ids = @($rows | ForEach-Object { [int](($_ -split ' ')[1].Substring(1)) })
    $got = ($rows | ForEach-Object { $f = $_ -split ' '; $id = [int]$f[1].Substring(1); $r = @($ids | Where-Object { $_ -lt $id }).Count; "{0}:{1}:{2},{3}:{4}x{5}:{6}" -f $f[0], $r, $f[2], $f[3], $f[4], $f[5], $f[6] }) -join ' '
    P kill-session -t $s | Out-Null
    if ($got -eq $wantPanes -and $lay -eq (Strip-Layout $wantLayout)) {
        Write-Host "  [PASS] $name  $got" -ForegroundColor Green; $script:Pass++
    } else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        Write-Host "         tmux : $wantPanes   $(Strip-Layout $wantLayout)"
        Write-Host "         psmux: $got   $lay"
        $script:Fail++
    }
}

P kill-server | Out-Null
Write-Host "`nPassed: $script:Pass  Failed: $script:Fail" -ForegroundColor Cyan
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
