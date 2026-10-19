@echo off
rem mihomo-kit tray installer launcher (ASCII-only on purpose)
rem Place the whole "tray" folder + panel-icon*.ico inside your mihomo-kit root, then run this.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
