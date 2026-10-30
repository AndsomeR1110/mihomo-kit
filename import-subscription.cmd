@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\import-subscription.ps1" %*
