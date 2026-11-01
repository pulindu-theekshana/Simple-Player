@echo off
cd /d "%~dp0"
set "MPV=mpv"
if exist "C:\Program Files\MPV Player\mpv.exe" set "MPV=C:\Program Files\MPV Player\mpv.exe"
if exist "%~dp0mpv\mpv.exe" set "MPV=%~dp0mpv\mpv.exe"
if exist "%~dp0mpv\SimplePlayer.exe" set "MPV=%~dp0mpv\SimplePlayer.exe"
"%MPV%" --config-dir="%~dp0config" %*