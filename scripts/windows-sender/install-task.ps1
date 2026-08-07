# Registers a scheduled task that applies the Voicemeeter VBAN configuration at
# every logon.
#
# Run from an ordinary PowerShell prompt. Administrator is not required: the task
# runs as you, in your own session.
#
# The task MUST run in the interactive session. Voicemeeter's Remote API talks
# through session scoped shared memory, so a task configured to "run whether user
# is logged on or not" cannot see Voicemeeter at all.

param(
    [string]$TaskName = "OfficeAudioHub",
    [int]$DelaySeconds = 25
)

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs  = Join-Path $here "launch.vbs"
if (-not (Test-Path $vbs)) { throw "launch.vbs not found next to this script" }

$user = "$env:USERDOMAIN\$env:USERNAME"

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`""

# The delay gives audio devices time to enumerate. Without it the script can run
# before Voicemeeter's virtual cards are ready.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = "PT${DelaySeconds}S"

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -Hidden `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Starts Voicemeeter and applies the office-audio VBAN configuration." | Out-Null

Write-Host "Registered task '$TaskName' for $user."
Write-Host ""
Write-Host "Test it now with:"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Get-ScheduledTaskInfo -TaskName '$TaskName' | Select LastRunTime, LastTaskResult"
Write-Host "  Get-Content `"`$env:LOCALAPPDATA\office-audio\apply-vban.log`""
Write-Host ""
Write-Host "LastTaskResult of 0 means it ran. The log says what it actually applied."
Write-Host ""
Write-Host "Do NOT also enable Voicemeeter's own 'Run on Windows Startup'."
Write-Host "Voicemeeter is single instance, so a second launch just opens its window."
