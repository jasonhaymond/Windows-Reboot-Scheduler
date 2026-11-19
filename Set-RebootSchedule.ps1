<#
.SYNOPSIS
    Interactively creates a Windows scheduled task that reboots this computer.

.DESCRIPTION
    Asks how often and when to reboot (once, daily, or weekly), how much warning
    to give logged-on users, and what message to show them. It then registers a
    task under \RebootScheduler\ that runs shutdown.exe as SYSTEM. The same menu
    can list and remove the tasks it created.

    Needs Administrator rights. If you start it without them it relaunches
    itself elevated, with the execution policy bypassed for that process only.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-RebootSchedule.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Bypass the execution policy for this process only. Harmless when the script was
# already started with -ExecutionPolicy Bypass, and silently skipped when Group
# Policy enforces a policy.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }

$TaskFolder     = '\RebootScheduler\'
$DefaultName    = 'Scheduled Reboot'
$DefaultMessage = 'This computer will restart for scheduled maintenance.'
$ShutdownExe    = Join-Path $env:SystemRoot 'System32\shutdown.exe'

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor Cyan
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $suffix = ''
    if ($Default) { $suffix = " [$Default]" }
    $answer = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $hint = 'y/N'
    if ($Default) { $hint = 'Y/n' }
    while ($true) {
        $answer = Read-Host "$Prompt ($hint)"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
        }
        Write-Host 'Please answer y or n.' -ForegroundColor Yellow
    }
}

function Read-Choice {
    param([string]$Prompt, [string[]]$Options, [int]$Default = 1)
    Write-Host ''
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ('  {0}) {1}' -f ($i + 1), $Options[$i])
    }
    while ($true) {
        $text = Read-Default 'Enter a number' ([string]$Default)
        $n = 0
        if ([int]::TryParse($text, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $Options[$n - 1]
        }
        Write-Host ('Enter a number from 1 to {0}.' -f $Options.Count) -ForegroundColor Yellow
    }
}

function Read-Int {
    param([string]$Prompt, [int]$Default, [int]$Min, [int]$Max)
    while ($true) {
        $text = Read-Default $Prompt ([string]$Default)
        $n = 0
        if ([int]::TryParse($text, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-Host ('Enter a whole number from {0} to {1}.' -f $Min, $Max) -ForegroundColor Yellow
    }
}

function Read-TimeOfDay {
    param([string]$Default = '03:00')
    $formats = [string[]]@('H:mm', 'h:mm tt', 'h:mmtt', 'h tt', 'htt')
    while ($true) {
        $text = Read-Default 'Time of day (24-hour like 03:00, or 3:00 AM)' $Default
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($text, $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$parsed)) {
            return $parsed
        }
        Write-Host 'Could not read that time. Try 03:00 or 3:00 AM.' -ForegroundColor Yellow
    }
}

function Read-DateOnly {
    $formats = [string[]]@('yyyy-MM-dd', 'M/d/yyyy')
    $default = (Get-Date).AddDays(1).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    while ($true) {
        $text = Read-Default 'Date (yyyy-MM-dd or M/d/yyyy)' $default
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($text, $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
        Write-Host 'Could not read that date. Example: 2026-12-01' -ForegroundColor Yellow
    }
}

function Read-DaysOfWeek {
    $names = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    Write-Host ''
    Write-Host 'Which days?'
    for ($i = 0; $i -lt 7; $i++) {
        Write-Host ('  {0}) {1}' -f ($i + 1), $names[$i])
    }
    while ($true) {
        $text   = Read-Default 'Enter numbers separated by commas, e.g. 1,4' '7'
        $picked = @()
        $valid  = $true
        foreach ($part in ($text -split '[,\s]+')) {
            if ($part -eq '') { continue }
            $n = 0
            if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le 7) {
                $picked += $names[$n - 1]
            }
            else {
                $valid = $false
            }
        }
        if ($valid -and $picked.Count -gt 0) {
            return @($picked | Select-Object -Unique)
        }
        Write-Host 'Enter numbers from 1 to 7, e.g. 1,4' -ForegroundColor Yellow
    }
}

function Format-RunTime($Value) {
    if ($null -eq $Value -or $Value.Year -lt 2000) { return '-' }
    return $Value.ToString('g')
}

function Get-OurTasks {
    Get-ScheduledTask -TaskPath $TaskFolder -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Actions
# ----------------------------------------------------------------------------

function New-RebootTask {
    Write-Title 'Create a scheduled reboot'

    while ($true) {
        $name = Read-Default 'Task name' $DefaultName
        if ($name -notmatch '[\\/:*?"<>|]') { break }
        Write-Host 'Task names cannot contain \ / : * ? " < > |' -ForegroundColor Yellow
    }

    $frequency = Read-Choice 'How often should it reboot?' @('Once', 'Daily', 'Weekly') 3
    Write-Host ''

    switch ($frequency) {
        'Once' {
            while ($true) {
                $date = Read-DateOnly
                $time = Read-TimeOfDay '03:00'
                $when = $date.Date.Add($time.TimeOfDay)
                if ($when -gt (Get-Date)) { break }
                Write-Host 'That date and time is already in the past. Try again.' -ForegroundColor Yellow
            }
            $trigger      = New-ScheduledTaskTrigger -Once -At $when
            $scheduleText = 'Once, on {0}' -f $when.ToString('f')
        }
        'Daily' {
            $time         = Read-TimeOfDay '03:00'
            $trigger      = New-ScheduledTaskTrigger -Daily -At $time
            $scheduleText = 'Every day at {0}' -f $time.ToString('t')
        }
        'Weekly' {
            $days         = @(Read-DaysOfWeek)
            $time         = Read-TimeOfDay '03:00'
            $trigger      = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $time
            $scheduleText = 'Every {0} at {1}' -f ($days -join ', '), $time.ToString('t')
        }
    }

    Write-Host ''
    $delay = Read-Int 'Seconds of warning before the reboot (0-3600)' 60 0 3600

    $message = (Read-Default 'Message shown to logged-on users' $DefaultMessage) -replace '"', "'"
    $message = $message.TrimEnd('\')
    if ($message.Length -gt 500) { $message = $message.Substring(0, 500) }

    # /f is always used: this reboot is unattended, so apps that don't close on
    # their own must not be able to block it. (shutdown.exe implies /f for any
    # /t above 0 anyway.)
    $shutdownArgs = '/r /f /t {0} /c "{1}"' -f $delay, $message

    Write-Title 'Summary'
    Write-Host ('  Task:      {0}{1}' -f $TaskFolder, $name)
    Write-Host ('  Schedule:  {0}' -f $scheduleText)
    Write-Host ('  Warning:   {0} seconds' -f $delay)
    Write-Host ('  Message:   {0}' -f $message)
    Write-Host '  Runs as:   SYSTEM, whether or not anyone is logged on'
    Write-Host '  Note:      Open apps are force-closed when the countdown ends; unsaved work is lost.'
    Write-Host '             Run "shutdown /a" during the countdown to cancel that reboot.'
    Write-Host ''

    if (-not (Read-YesNo 'Create this task?' $true)) {
        Write-Host 'Cancelled. Nothing was changed.'
        return
    }

    $existing = Get-ScheduledTask -TaskName $name -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    if ($existing) {
        if (-not (Read-YesNo "A task named '$name' already exists. Replace it?" $false)) {
            Write-Host 'Cancelled. Nothing was changed.'
            return
        }
    }

    $action    = New-ScheduledTaskAction -Execute $ShutdownExe -Argument $shutdownArgs
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # StartWhenAvailable is left off on purpose: if the PC was off at the scheduled
    # time, it must not reboot itself right after it next boots.
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    Register-ScheduledTask -TaskName $name -TaskPath $TaskFolder -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Created by Set-RebootSchedule.ps1' -Force | Out-Null

    $info = Get-ScheduledTaskInfo -TaskName $name -TaskPath $TaskFolder
    Write-Host ''
    Write-Host ('Created. Next run: {0}' -f (Format-RunTime $info.NextRunTime)) -ForegroundColor Green
}

function Show-RebootTasks {
    Write-Title 'Scheduled reboots'
    $tasks = @(Get-OurTasks)
    if ($tasks.Count -eq 0) {
        Write-Host 'No scheduled reboots found.'
        return
    }
    $rows = foreach ($task in $tasks) {
        $info = Get-ScheduledTaskInfo -InputObject $task
        [pscustomobject]@{
            Name    = $task.TaskName
            State   = [string]$task.State
            NextRun = (Format-RunTime $info.NextRunTime)
            LastRun = (Format-RunTime $info.LastRunTime)
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
}

function Remove-RebootTask {
    Write-Title 'Remove a scheduled reboot'
    $tasks = @(Get-OurTasks)
    if ($tasks.Count -eq 0) {
        Write-Host 'No scheduled reboots found.'
        return
    }
    $names = @($tasks | ForEach-Object { $_.TaskName })
    $name  = Read-Choice 'Which one?' $names 1
    if (Read-YesNo "Remove '$name'?" $false) {
        Unregister-ScheduledTask -TaskName $name -TaskPath $TaskFolder -Confirm:$false
        Write-Host "Removed '$name'." -ForegroundColor Green
    }
    else {
        Write-Host 'Cancelled. Nothing was changed.'
    }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

try {
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'The ScheduledTasks PowerShell module is not available. Windows 8 / Server 2012 or newer is required.'
    }

    if (-not (Test-IsAdmin)) {
        if (-not $PSCommandPath) {
            throw 'Please run this script from an elevated (Administrator) PowerShell window.'
        }
        Write-Host 'Administrator rights are needed to create scheduled tasks. Relaunching elevated...' -ForegroundColor Yellow
        $hostExe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        return
    }

    $running = $true
    while ($running) {
        Write-Title 'Reboot Scheduler'
        Write-Host '  1) Create a scheduled reboot'
        Write-Host '  2) List scheduled reboots'
        Write-Host '  3) Remove a scheduled reboot'
        Write-Host '  4) Quit'
        $choice = (Read-Host 'Choose 1-4').Trim()

        try {
            switch ($choice) {
                '1'     { New-RebootTask }
                '2'     { Show-RebootTasks }
                '3'     { Remove-RebootTask }
                '4'     { $running = $false }
                default { Write-Host 'Please choose 1, 2, 3 or 4.' -ForegroundColor Yellow }
            }
        }
        catch {
            Write-Host ('Error: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}
catch {
    Write-Host ''
    Write-Host ('Error: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
