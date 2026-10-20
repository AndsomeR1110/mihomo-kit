@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\clean-stray.ps1" %*
