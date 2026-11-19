@echo off
rem Starts Set-RebootSchedule.ps1 with the execution policy bypassed for this one
rem process only. Your system-wide PowerShell execution policy is not changed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-RebootSchedule.ps1"
if errorlevel 1 pause
