@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\proxy-mode.ps1" %*
