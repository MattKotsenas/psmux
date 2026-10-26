# Helper for tests/test_nested_client_color_leak.ps1
#
# Runs INSIDE a psmux popup and records the PSMUX_HOST_COLORS its parent planted
# on it. Kept as a file rather than an inline -E string on purpose: a popup
# command with nested quoting silently fails to spawn, which reads as "the value
# was empty" and sends you hunting a bug that is not there.
param([string]$OutFile = "$env:TEMP\psmux_popup_host_colors.txt")
"[" + $env:PSMUX_HOST_COLORS + "]" | Set-Content -Path $OutFile -Encoding UTF8
Start-Sleep -Seconds 3
