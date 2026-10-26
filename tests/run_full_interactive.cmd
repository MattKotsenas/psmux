@echo off
REM Thin launcher for the FULL psmux test suite in a dedicated console window.
REM
REM All of the logic (single instance guard, environment scrub, banner, exit code
REM reporting) lives in run_full_interactive.ps1. It used to be inlined here as
REM one pwsh -Command with caret continuations and nested escaped quotes, which
REM was unreadable and made the guard hard to get right. It is a script now.
REM
REM Any extra arguments (for example -Resume, or -Only <name>) are forwarded
REM straight through to run_all_tests.ps1.
REM
REM ---------------------------------------------------------------------------
REM THE FINAL PAUSE, AND THE TWO CASES THAT SKIP IT
REM
REM This window ends at `pause` on purpose: a human who double clicks the
REM launcher needs the summary to still be on screen when the run finishes.
REM
REM But a console parked at "Press any key to continue" is a process that lives
REM for ever, and on Windows 11 every console is delegated to Windows Terminal,
REM so it is also a visible tab nobody closes. Three sweeps launched from an
REM automation session left five of these behind on their own, next to the 121
REM orphaned `cmd /c pause` consoles the runner now audits per suite. A pause
REM that nobody will ever press a key for is not a feature, so it is skipped in
REM the two cases where there is provably no human watching:
REM
REM   1. PSMUX_RUN_NOPAUSE is set (to anything). Set it when a script, an agent
REM      session or CI launches a sweep and will read summary.log instead. The
REM      main session sets it when it dispatches sweeps.
REM
REM   2. The run was started without an interactive console. Detected by asking
REM      cmd whether its own stdin is a character device that can actually be
REM      read: a redirected, closed or null stdin makes `pause` return instantly
REM      anyway on some hosts and hang for ever on others, and neither is wanted.
REM      The probe is `<nul set /p` on a copy of the handle, which is cheap and
REM      has no side effects.
REM
REM In both cases the summary is still complete in the log directory the runner
REM prints, and in progress.log / summary.log.
REM ---------------------------------------------------------------------------
title psmux FULL test suite (interactive)
cd /d "%~dp0\.."

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_full_interactive.ps1" %*

set RC=%ERRORLEVEL%
echo.
echo ============================================================
if "%RC%"=="99" (
  echo   NOT STARTED - another run was already active
) else if "%RC%"=="130" (
  echo   RUN INTERRUPTED - stopped on request, remaining suites did not run
  echo   Resume with: tests\run_full_interactive.cmd -Resume
) else (
  echo   RUN COMPLETE  -  exit code %RC%
)
echo   Finished: %DATE% %TIME%
echo ============================================================

if defined PSMUX_RUN_NOPAUSE (
  echo This window closes itself: PSMUX_RUN_NOPAUSE is set.
  exit /b %RC%
)

REM Is there a real console on stdin? pwsh answers this accurately; cmd cannot.
REM A non-zero exit means "no interactive console", so do not park here.
pwsh -NoProfile -ExecutionPolicy Bypass -Command "exit $([int](-not ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)))" >nul 2>&1
if errorlevel 1 (
  echo This window closes itself: no interactive console to read the summary.
  exit /b %RC%
)

echo This window stays open so the summary is readable.
pause
exit /b %RC%
