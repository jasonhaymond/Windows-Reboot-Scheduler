# Windows Reboot Scheduler

A small interactive PowerShell script that creates a Windows scheduled task to reboot your computer on a schedule. It asks a few questions, shows a summary, and registers the task for you.

## Quick start

1. Download or clone this repo.
2. Double-click **`Run.cmd`**.
3. Accept the UAC prompt and answer the questions.

`Run.cmd` starts the script with `-ExecutionPolicy Bypass` for that one process, so you don't need to change your PowerShell execution policy, and files downloaded as a ZIP won't be blocked. The script also relaunches itself elevated (again with Bypass) if it isn't already running as Administrator.

Prefer a terminal?

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-RebootSchedule.ps1
```

## What it asks

| Question | Notes |
| --- | --- |
| Task name | Default: `Scheduled Reboot` |
| How often | Once, Daily, or Weekly (default: Weekly) |
| Date / days / time | A date for Once, days of the week for Weekly, and a time (`03:00` or `3:00 AM`) |
| Seconds of warning | 0-3600, default 60 |
| Message | Shown to logged-on users during the countdown |

The menu can also list and remove the tasks it created. They live in Task Scheduler under `\RebootScheduler\`, so it never touches your other tasks.

## Good to know

- **Runs as SYSTEM**, so the reboot happens whether or not anyone is logged on.
- **Open apps are force-closed** when the countdown ends (`shutdown /r /f`). Unsaved work is lost. Run `shutdown /a` during the countdown to cancel that reboot.
- **Missed runs are skipped.** If the PC is off or asleep at the scheduled time, it won't reboot itself later when it wakes or boots.
- Requires Windows 8 / Server 2012 or newer. Works with Windows PowerShell 5.1.

To remove a task without the menu:

```powershell
Unregister-ScheduledTask -TaskName 'Scheduled Reboot' -TaskPath '\RebootScheduler\' -Confirm:$false
```

## License

[MIT](LICENSE)
