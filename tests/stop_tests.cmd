@echo off
REM Stop the running psmux test suite cleanly, from any window.
REM
REM The runner console cannot be relied on for Ctrl+C: test suites launch
REM attached psmux clients whose windows take the foreground, so the keyboard
REM stops reaching the runner seconds into a run. Run this from any other shell
REM instead. All logic lives in stop_tests.ps1.
REM
REM   tests\stop_tests.cmd            stop the active run and wait for it
REM   tests\stop_tests.cmd -Force     also kill the runner if it will not stop
title psmux stop test run

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop_tests.ps1" %*
exit /b %ERRORLEVEL%
