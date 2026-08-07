# Creates a desktop shortcut that starts Voicemeeter and applies the VBAN
# configuration, with a self-dismissing confirmation.
#
# This is the recovery button. Voicemeeter exits rather than minimising when you
# close its window (unless "System Tray (Close = Hide)" is enabled), and it comes
# back with DEFAULT settings, so reopening it does not restore anything. Double
# clicking this fixes it in one step.
#
# Run from an ordinary PowerShell prompt. Administrator is not required.

param(
    [string]$Name = "Start Audio Hub"
)

$ErrorActionPreference = "Stop"

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner = Join-Path $here "runner.vbs"
if (-not (Test-Path $runner)) { throw "runner.vbs not found next to this script" }

# Resolve the real Desktop rather than assuming ~\Desktop. It is commonly
# redirected to OneDrive, in which case the assumed path does not exist.
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop "$Name.lnk"

$voicemeeter = "C:\Program Files (x86)\VB\Voicemeeter\voicemeeterpro.exe"

$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($lnkPath)
$lnk.TargetPath       = "wscript.exe"
$lnk.Arguments        = "`"$runner`" popup"
$lnk.WorkingDirectory = $here
$lnk.Description      = "Start Voicemeeter and apply the office-audio VBAN configuration"
if (Test-Path $voicemeeter) { $lnk.IconLocation = "$voicemeeter,0" }
$lnk.Save()

Write-Host "Created: $lnkPath"
Write-Host ""
Write-Host "Double click it any time the Windows side stops working."
Write-Host "A cold start takes roughly 30 to 45 seconds and several internal"
Write-Host "passes, then shows a confirmation that dismisses itself."
Write-Host ""
Write-Host "What it did is logged to:"
Write-Host "  `$env:LOCALAPPDATA\office-audio\apply-vban.log"
