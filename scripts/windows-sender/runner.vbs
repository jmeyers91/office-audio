' Drives apply-vban.ps1 until it reports success.
'
'   wscript runner.vbs           silent, used by the logon scheduled task
'   wscript runner.vbs popup     shows a self-dismissing result, used by the
'                                desktop shortcut
'
' Each pass is a FRESH PowerShell process on purpose. apply-vban.ps1 does one
' thing per run and exits 2 when it needs another pass, for example after
' starting Voicemeeter or after restarting the audio engine. Writes made while
' the engine is restarting are silently discarded, and an earlier version that
' looped inside a single process died partway through, leaving Voicemeeter
' running on default settings with nothing useful in the log.
'
' Typical cold start takes three or four passes:
'   pass 1  starts Voicemeeter
'   pass 2  fixes A1 and restarts the audio engine
'   pass 3  writes are discarded because the engine is still settling
'   pass 4  applied and verified
'
' The confirmation uses Popup with a timeout rather than MsgBox so it dismisses
' itself and can never sit blocking a machine nobody is looking at.

Const MAX_PASSES = 6
Const WAIT_BETWEEN_PASSES = 6    ' seconds, lets the audio engine settle
Const POPUP_SECONDS = 12
Const ICON_INFO = 64
Const ICON_ERROR = 16

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

showPopup = False
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "popup" Then showPopup = True
End If

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "apply-vban.ps1")
logFile = fso.BuildPath(sh.ExpandEnvironmentStrings("%LOCALAPPDATA%"), "office-audio\apply-vban.log")

If Not fso.FileExists(ps1) Then
    If showPopup Then sh.Popup "Cannot find apply-vban.ps1 in:" & vbCrLf & scriptDir, _
                               POPUP_SECONDS, "office-audio", ICON_ERROR
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"

ok = False
fatal = False

For pass = 1 To MAX_PASSES
    ' 0 = hidden window, True = wait so the exit code can be read
    rc = sh.Run(cmd, 0, True)

    If rc = 0 Then
        ok = True
        Exit For
    ElseIf rc = 1 Then
        fatal = True
        Exit For
    End If

    ' rc = 2 means progress was made, or the process died partway through.
    ' Either way, another pass is the right response.
    WScript.Sleep WAIT_BETWEEN_PASSES * 1000
Next

If showPopup Then
    If ok Then
        sh.Popup "Audio hub is ready." & vbCrLf & vbCrLf & _
                 "Select the hub output device and audio will play through the " & _
                 "speakers connected to it.", _
                 POPUP_SECONDS, "office-audio", ICON_INFO
    ElseIf fatal Then
        sh.Popup "Setup failed." & vbCrLf & vbCrLf & "See:" & vbCrLf & logFile, _
                 POPUP_SECONDS, "office-audio", ICON_ERROR
    Else
        sh.Popup "Gave up after " & MAX_PASSES & " attempts." & vbCrLf & vbCrLf & _
                 "See:" & vbCrLf & logFile, _
                 POPUP_SECONDS, "office-audio", ICON_ERROR
    End If
End If

If ok Then WScript.Quit 0
WScript.Quit 1
