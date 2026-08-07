# office-audio: apply the Voicemeeter VBAN configuration that sends this PC's
# "hub" output device to the Linux hub.
#
# Run it once by hand to configure Voicemeeter, or register it with
# install-task.ps1 to reapply at every logon.
#
# Reapplying at logon is deliberate. Voicemeeter only writes its settings on a
# clean exit, and it does not always do so, which makes its persistence hard to
# rely on. Reasserting the config every boot is cheap and deterministic.
#
# See docs/sender-windows.md for what this is doing and why.

# ===========================================================================
# SETTINGS
# ===========================================================================

# Address of the Linux hub.
$HubIp = "192.0.2.10"

# Hub port for the destination you want. See the port table in the README.
$HubPort = 6980

# Must match audio.rate on the hub's VBAN receiver. PipeWire uses its configured
# rate, not the packet header, so a mismatch plays at the wrong speed.
$SampleRate = 44100

# Label only. The PipeWire receiver does not filter on it.
$StreamName = "HubOutput"

# Which Voicemeeter virtual input becomes the hub device.
#   Banana: 3 = VAIO ("VoiceMeeter Input"), 4 = AUX ("VoiceMeeter Aux Input")
# Using AUX leaves VAIO free for normal use.
$StripIndex = 4

# Which bus carries the stream, by index.
#   Banana buses in order: A1=0, A2=1, A3=2, B1=3, B2=4
# B2 is used here because it is normally unused.
$BusIndex = 4

# Voicemeeter will not run its audio engine unless A1 points at a device that
# EXISTS. Nothing is routed to A1 here, so it only ever receives silence, but it
# has to be valid. Set this to any real output on the machine, exactly as it
# appears in Voicemeeter's A1 menu. A monitor's HDMI output is a fine choice.
# Leave empty to skip the check and fix A1 by hand instead.
$FallbackA1Device = ""

$VoicemeeterExe = "C:\Program Files (x86)\VB\Voicemeeter\voicemeeterpro.exe"
$RemoteDll      = "C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll"

# ===========================================================================

$ErrorActionPreference = "Continue"
$logDir = Join-Path $env:LOCALAPPDATA "office-audio"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "apply-vban.log"
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File -FilePath $log -Append -Encoding utf8 }

Log "=== start ==="

if (-not (Test-Path $VoicemeeterExe)) { Log "FATAL: Voicemeeter not found at $VoicemeeterExe"; exit 1 }

if (-not (Get-Process -Name "voicemeeterpro" -ErrorAction SilentlyContinue)) {
    Log "starting Voicemeeter"
    Start-Process $VoicemeeterExe
    Start-Sleep -Seconds 10
} else {
    Log "Voicemeeter already running"
}

$src = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VMR {
  const string DLL = @"$RemoteDll";
  [DllImport(DLL)] public static extern int VBVMR_Login();
  [DllImport(DLL)] public static extern int VBVMR_Logout();
  [DllImport(DLL)] public static extern int VBVMR_IsParametersDirty();
  [DllImport(DLL)] public static extern int VBVMR_GetParameterFloat([MarshalAs(UnmanagedType.LPStr)] string p, ref float v);
  [DllImport(DLL)] public static extern int VBVMR_GetParameterStringA([MarshalAs(UnmanagedType.LPStr)] string p, StringBuilder s);
  [DllImport(DLL)] public static extern int VBVMR_SetParameterFloat([MarshalAs(UnmanagedType.LPStr)] string p, float v);
  [DllImport(DLL)] public static extern int VBVMR_SetParameterStringA([MarshalAs(UnmanagedType.LPStr)] string p, [MarshalAs(UnmanagedType.LPStr)] string s);
}
"@
try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop } catch { Log "Add-Type: $_" }

# Login returns 0 on success. It returns 1 when Voicemeeter is not reachable,
# which most often means this script is running outside the interactive session:
# the Remote API uses session scoped shared memory.
$rc = [VMR]::VBVMR_Login()
Log "Login rc=$rc"
if ($rc -lt 0) { Log "FATAL: cannot reach Voicemeeter"; exit 1 }
Start-Sleep -Milliseconds 1200

# REQUIRED. Set calls made before the dirty flag drains return success and do
# nothing at all.
function Drain {
    for ($i = 0; $i -lt 40; $i++) {
        if ([VMR]::VBVMR_IsParametersDirty() -eq 0) { return $i }
        Start-Sleep -Milliseconds 100
    }
    return -1
}
Log "dirty drained after $(Drain) polls"

# --- A1 has to be a device that exists or the audio engine never runs -------
if ($FallbackA1Device -ne "") {
    $sb = New-Object System.Text.StringBuilder 512
    [VMR]::VBVMR_GetParameterStringA("Bus[0].device.name", $sb) | Out-Null
    $a1 = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($a1)) {
        Log "A1 empty, setting to '$FallbackA1Device'"
        [VMR]::VBVMR_SetParameterStringA("Bus[0].device.wdm", $FallbackA1Device) | Out-Null
        Start-Sleep -Milliseconds 500
        # hardware output changes only take effect on an engine restart
        [VMR]::VBVMR_SetParameterFloat("Command.Restart", 1) | Out-Null
        Start-Sleep -Seconds 6
        Drain | Out-Null
    } else {
        Log "A1 = '$a1'"
    }
}

# --- dedicate the chosen virtual input to the hub --------------------------
foreach ($b in @("A1","A2","A3","B1","B2")) {
    [VMR]::VBVMR_SetParameterFloat("Strip[$StripIndex].$b", 0) | Out-Null
}
$busName = @("A1","A2","A3","B1","B2")[$BusIndex]
[VMR]::VBVMR_SetParameterFloat("Strip[$StripIndex].$busName", 1) | Out-Null
[VMR]::VBVMR_SetParameterFloat("Strip[$StripIndex].mute", 0) | Out-Null
[VMR]::VBVMR_SetParameterFloat("Strip[$StripIndex].gain", 0) | Out-Null
[VMR]::VBVMR_SetParameterFloat("Bus[$BusIndex].mute", 0) | Out-Null
[VMR]::VBVMR_SetParameterFloat("Bus[$BusIndex].gain", 0) | Out-Null

# --- sample rate cannot be changed while the stream is on ------------------
$f = 0.0
[VMR]::VBVMR_GetParameterFloat("vban.outstream[0].sr", [ref]$f) | Out-Null
if ([int]$f -ne $SampleRate) {
    Log "sr is $f, toggling stream off to change it"
    [VMR]::VBVMR_SetParameterFloat("vban.outstream[0].on", 0) | Out-Null
    Start-Sleep -Seconds 2
    [VMR]::VBVMR_SetParameterFloat("vban.outstream[0].sr", $SampleRate) | Out-Null
    Start-Sleep -Seconds 2
}

# --- the outgoing stream ---------------------------------------------------
[VMR]::VBVMR_SetParameterStringA("vban.outstream[0].name", $StreamName) | Out-Null
[VMR]::VBVMR_SetParameterStringA("vban.outstream[0].ip", $HubIp) | Out-Null
[VMR]::VBVMR_SetParameterFloat("vban.outstream[0].port", $HubPort) | Out-Null
[VMR]::VBVMR_SetParameterFloat("vban.outstream[0].channel", 2) | Out-Null
[VMR]::VBVMR_SetParameterFloat("vban.outstream[0].bit", 16) | Out-Null
[VMR]::VBVMR_SetParameterFloat("vban.outstream[0].quality", 1) | Out-Null
[VMR]::VBVMR_SetParameterFloat("vban.outstream[0].route", $BusIndex) | Out-Null
[VMR]::VBVMR_SetParameterFloat("vban.outstream[0].on", 1) | Out-Null
[VMR]::VBVMR_SetParameterFloat("vban.Enable", 1) | Out-Null
Start-Sleep -Seconds 2

# --- read back so the log proves what actually landed ----------------------
$nm  = New-Object System.Text.StringBuilder 512
$ipb = New-Object System.Text.StringBuilder 512
[VMR]::VBVMR_GetParameterStringA("vban.outstream[0].name", $nm) | Out-Null
[VMR]::VBVMR_GetParameterStringA("vban.outstream[0].ip", $ipb) | Out-Null
$v = @{}
foreach ($p in @("vban.Enable","vban.outstream[0].on","vban.outstream[0].port",
                 "vban.outstream[0].sr","vban.outstream[0].route","Strip[$StripIndex].$busName")) {
    [VMR]::VBVMR_GetParameterFloat($p, [ref]$f) | Out-Null
    $v[$p] = $f
}
Log ("applied: name='{0}' ip='{1}' on={2} port={3} sr={4} route={5} strip->{6}={7}" -f `
     $nm.ToString(), $ipb.ToString(), $v["vban.outstream[0].on"], $v["vban.outstream[0].port"],
     $v["vban.outstream[0].sr"], $v["vban.outstream[0].route"], $busName, $v["Strip[$StripIndex].$busName"])

[VMR]::VBVMR_Logout() | Out-Null
Log "=== done ==="
