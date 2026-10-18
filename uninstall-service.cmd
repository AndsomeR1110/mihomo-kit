@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall-service.ps1" %*
