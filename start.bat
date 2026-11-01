@echo off
cd /d "%~dp0"
set "MPV=C:\Program Files\MPV Player\mpv.exe"
if exist "%~dp0mpv\mpv.exe" set "MPV=%~dp0mpv\mpv.exe"
"%MPV%" --config-dir="%~dp0config" %*
