@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\logs.ps1" %*
