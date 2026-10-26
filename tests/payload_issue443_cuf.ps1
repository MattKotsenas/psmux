$e = [char]27
Write-Host ("SPCA" + "    " + "SPCB" + "    " + "SPCC")
Write-Host ("CUFA${e}[4CCUFB${e}[4CCUFC${e}[4CCUFD")
Write-Host ("CHAA${e}[10GCHAB${e}[20GCHAC")
# wide-char regression: CJK should NOT gain phantom spaces
Write-Host ("WIDE:" + [char]0x4E2D + [char]0x6587 + ":END")
