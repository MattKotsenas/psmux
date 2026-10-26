; psmux NSIS Installer Script
; Builds a self-extracting installer that:
;   1. Kills running psmux servers before install/uninstall
;   2. Installs psmux.exe, pmux.exe, tmux.exe
;   3. Adds install dir to user PATH
;   4. Runs warmup after install
;
; Build with (from repo root):
;   makensis /NOCD /DVERSION=3.2.0 /DARCH=x64 /DSOURCE_DIR=<abs>\target\release /DREPO_DIR=<abs> installer\psmux.nsi
;   Or use: .\scripts\build.ps1
;
; Required defines (passed via /D on command line):
;   VERSION    - e.g. "3.2.0"
;   ARCH       - "x64", "x86", or "arm64"
;   SOURCE_DIR - absolute path to folder containing psmux.exe, pmux.exe, tmux.exe
;   REPO_DIR   - absolute path to the repo root (for README, LICENSE)

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef ARCH
  !define ARCH "x64"
!endif
!ifndef SOURCE_DIR
  !define SOURCE_DIR "..\target\x86_64-pc-windows-msvc\release"
!endif
!ifndef REPO_DIR
  !define REPO_DIR ".."
!endif
; VIProductVersion must be numeric X.Y.Z.W, so a prerelease VERSION such as
; 3.4.0-signtest passes its numeric part as VI_VERSION.
!ifndef VI_VERSION
  !define VI_VERSION "${VERSION}"
!endif

; ── Uninstaller signing (optional) ───────────────────────────────────────
; WriteUninstaller emits uninstall.exe from inside makensis, so it cannot be
; signed after the build. !uninstfinalize (NSIS 3.08+) runs a command on the
; uninstaller before it is packed; %1 is the uninstaller's path.
;
;   SIGNTOOL + SIGN_THUMBPRINT  signtool.exe path and certificate SHA1; the
;                               release workflow passes these after the
;                               Certum login. Nothing here needs quoting on
;                               the makensis command line.
;   SIGN_CMD                    any full command containing "%1", for other
;                               signers or for testing the hook locally.
;
; With none of them defined the installer builds unsigned, as before.
!ifdef SIGNTOOL & SIGN_THUMBPRINT
  !ifndef SIGN_CMD
    !define SIGN_CMD '"${SIGNTOOL}" sign /sha1 ${SIGN_THUMBPRINT} /tr http://time.certum.pl /td SHA256 /fd SHA256 /d "psmux" "%1"'
  !endif
!endif
!ifdef SIGN_CMD
  !uninstfinalize '${SIGN_CMD}' = 0
  !ifdef SIGNTOOL
    !uninstfinalize '"${SIGNTOOL}" verify /pa /q "%1"' = 0
  !endif
!endif

; ── General ──────────────────────────────────────────────────────────────
Name "psmux ${VERSION}"
OutFile "${REPO_DIR}\target\installer\psmux-v${VERSION}-${ARCH}-setup.exe"
InstallDir "$LOCALAPPDATA\psmux"
InstallDirRegKey HKCU "Software\psmux" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
; The three binaries are near identical copies. LZMA can only reuse the
; first one inside its dictionary, and the default 8 MB is smaller than the
; x64 psmux.exe (9.45 MB at 3.3.8+), so all three were stored in full: 6.8 MB
; instead of 2.6 MB. 32 MB covers them (about 32 MB RAM while unpacking).
SetCompressorDictSize 32
Unicode True

; ── Version info embedded in the .exe ────────────────────────────────────
VIProductVersion "${VI_VERSION}.0"
VIAddVersionKey "ProductName" "psmux"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "psmux - Terminal Multiplexer for Windows"
VIAddVersionKey "LegalCopyright" "Copyright (c) Josh"
VIAddVersionKey "FileVersion" "${VERSION}"

; ── Pages ────────────────────────────────────────────────────────────────
!include "MUI2.nsh"

!insertmacro MUI_PAGE_LICENSE "${REPO_DIR}\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ── Macros ───────────────────────────────────────────────────────────────
; Kill running psmux servers — used by both install and uninstall
!macro KillPsmuxServers
  ; Try graceful kill-server via existing installed binary. `-a` because the
  ; installer must free EVERY namespace's binary, not just the default one
  ; (a bare kill-server is socket scoped since #649).
  IfFileExists "$INSTDIR\psmux.exe" 0 +3
    DetailPrint "Running psmux kill-server -a..."
    nsExec::ExecToLog '"$INSTDIR\psmux.exe" kill-server -a'

  ; Force-kill any remaining processes
  DetailPrint "Force-killing remaining psmux/pmux/tmux processes..."
  nsExec::ExecToLog 'taskkill /F /IM psmux.exe'
  nsExec::ExecToLog 'taskkill /F /IM pmux.exe'
  nsExec::ExecToLog 'taskkill /F /IM tmux.exe'

  ; Wait for file handles to release
  Sleep 1500
!macroend

; ── Install Section ──────────────────────────────────────────────────────
Section "Install"
  ; Kill running servers BEFORE overwriting files
  !insertmacro KillPsmuxServers

  SetOutPath "$INSTDIR"

  ; Install files
  File "${SOURCE_DIR}\psmux.exe"
  File "${SOURCE_DIR}\pmux.exe"
  File "${SOURCE_DIR}\tmux.exe"
  File "${REPO_DIR}\README.md"
  File "${REPO_DIR}\LICENSE"

  ; Write uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Write registry keys for Add/Remove Programs
  WriteRegStr HKCU "Software\psmux" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "DisplayName" "psmux - Terminal Multiplexer for Windows"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "Publisher" "Godwin Sam Josh"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "URLInfoAbout" "https://github.com/psmux/psmux"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux" \
    "NoRepair" 1

  ; Add to user PATH
  DetailPrint "Adding to user PATH..."
  EnVar::SetHKCU
  EnVar::AddValue "Path" "$INSTDIR"
  Pop $0
  ${If} $0 = 0
    DetailPrint "Added $INSTDIR to PATH"
  ${Else}
    DetailPrint "PATH already contains $INSTDIR (or error: $0)"
  ${EndIf}

  ; Notify shell that environment changed
  SendMessage ${HWND_BROADCAST} ${WM_WININICHANGE} 0 "STR:Environment" /TIMEOUT=500

  ; Run warmup (async — don't block installer)
  DetailPrint "Running psmux warmup..."
  Exec '"$INSTDIR\psmux.exe" warmup'
SectionEnd

; ── Uninstall Section ────────────────────────────────────────────────────
Section "Uninstall"
  ; Kill running servers BEFORE removing files
  !insertmacro KillPsmuxServers

  ; Remove files
  Delete "$INSTDIR\psmux.exe"
  Delete "$INSTDIR\pmux.exe"
  Delete "$INSTDIR\tmux.exe"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  ; Remove from user PATH
  DetailPrint "Removing from user PATH..."
  EnVar::SetHKCU
  EnVar::DeleteValue "Path" "$INSTDIR"

  ; Remove registry keys
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\psmux"
  DeleteRegKey HKCU "Software\psmux"

  ; Notify shell that environment changed
  SendMessage ${HWND_BROADCAST} ${WM_WININICHANGE} 0 "STR:Environment" /TIMEOUT=500
SectionEnd
