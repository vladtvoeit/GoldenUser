@echo off
rem Запуск GoldenUser.ps1 без возни с ExecutionPolicy. Положите рядом с GoldenUser.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0GoldenUser.ps1"
