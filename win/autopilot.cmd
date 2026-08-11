@echo off
REM autopilot launcher for cmd.exe. Delegates to autopilot.ps1 (next to this file),
REM which re-parses the arguments so a quoted goal keeps its spaces, then forwards to
REM WSL or Git Bash. Requires autopilot to be installed inside that bash environment.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autopilot.ps1" %*
exit /b %errorlevel%
