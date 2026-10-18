@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\make-panel-shortcut.ps1" %*
