' Runs apply-vban.ps1 with no console window.
'
' Task Scheduler can run powershell.exe directly, but even with -WindowStyle
' Hidden a console briefly flashes at logon. Going through wscript avoids it.
'
' Expects apply-vban.ps1 to sit next to this file.

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "apply-vban.ps1")

sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
