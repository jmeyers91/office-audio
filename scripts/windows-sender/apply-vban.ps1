# office-audio: apply the Voicemeeter VBAN configuration, ONE pass.
#
# Exit codes:
#   0  config applied and verified
#   2  did useful work but needs another pass (started Voicemeeter, or fixed A1
#      and restarted the audio engine, or a write was discarded). Run it again.
#   1  something is actually wrong, see the log
#
# Deliberately does one thing per run and lets the caller re-invoke. runner.vbs
# drives the retries. An earlier version looped inside a single process and died
# silently partway through, leaving Voicemeeter running on default settings with
# nothing useful in the log. Writes made while the audio engine is restarting are
# discarded, so a fresh process per pass is the only reliable approach.
#
# Why any of this is needed at all:
#   - Voicemeeter only saves settings on a clean exit, and closing its window
#     kills it outright unless "System Tray (Close = Hide)" is enabled. A fresh
#     start therefore comes up with DEFAULTS, not your configuration.
#   - Voicemeeter will not run its audio engine unless A1 points at a device that
#     EXISTS, and reports no error when it does not. VBAN then sends nothing.
#   - VBVMR_IsParametersDirty() must drain to 0 after Login, or every Set is a
#     silent no-op that still returns success.
#   - vban.outstream[N].sr cannot be changed while the stream is on.
#
# See docs/sender-windows.md.

$ErrorActionPreference = "Continue"

# ============================== SETTINGS ===================================

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

# For a SECOND hub destination from this same machine, add a second stream on
# the other virtual input: Strip 3 (VAIO) -> bus B1 (3) -> vban.outstream[1] ->
# the other hub port. Each strip must feed only its own bus, and the hardware
# input strips default to B1, so clear B1 on those or a microphone leaks into
# that stream. See "If you want more than one hub destination" in
# docs/sender-windows.md.

# A real output device on this machine. Nothing is routed to A1, so it only ever
# receives silence, but it has to be valid or the audio engine will not run.
# A monitor's HDMI output is a good throwaway choice.
#
# Use the name WITHOUT any "WDM:" prefix, exactly as Voicemeeter reports it, for
# example "ASUS VG247Q1A (NVIDIA High Definition Audio)". Voicemeeter's A1 menu
# displays the prefix but the API does not want it.
#
# Run this to print the exact strings available on this machine:
#   .\list-devices.ps1
$A1Device = "REPLACE WITH A REAL OUTPUT DEVICE"

$VoicemeeterExe = "C:\Program Files (x86)\VB\Voicemeeter\voicemeeterpro.exe"
$RemoteDll      = "C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll"

# ===========================================================================

$logDir = Join-Path $env:LOCALAPPDATA "office-audio"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "apply-vban.log"
function Log($m) { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File -FilePath $log -Append -Encoding utf8 }

if (-not (Test-Path $RemoteDll)) {
    Log "FATAL: VoicemeeterRemote64.dll not found at $RemoteDll"
    Log "  If Voicemeeter is installed elsewhere, fix `$RemoteDll at the top of this script."
    exit 1
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
  [DllImport(DLL)] public static extern int VBVMR_Output_GetDeviceNumber();
  [DllImport(DLL)] public static extern int VBVMR_Output_GetDeviceDescA(int i, ref int type, StringBuilder name, StringBuilder hwid);
}
"@
# Guard rather than swallow. An empty catch here hides a genuinely failed
# Add-Type (wrong DLL path, 32-bit host), after which every call below fails
# non-terminatingly and the log never mentions the real cause.
if (-not ([System.Management.Automation.PSTypeName]'VMR').Type) {
    try {
        Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
    } catch {
        Log "FATAL: could not bind to VoicemeeterRemote64.dll: $_"
        exit 1
    }
}

function GetF($p) { $v = 0.0; [VMR]::VBVMR_GetParameterFloat($p, [ref]$v) | Out-Null; return $v }
function GetS($p) { $sb = New-Object System.Text.StringBuilder 512; [VMR]::VBVMR_GetParameterStringA($p, $sb) | Out-Null; return $sb.ToString() }

$busName = @("A1","A2","A3","B1","B2")[$BusIndex]

# --- 1. Voicemeeter has to be running --------------------------------------
if (-not (Get-Process -Name "voicemeeterpro" -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $VoicemeeterExe)) { Log "FATAL: Voicemeeter not found at $VoicemeeterExe"; exit 1 }
    Log "Voicemeeter not running, starting it"
    Start-Process $VoicemeeterExe
    exit 2
}

# --- 2. connect -------------------------------------------------------------
$rc = [VMR]::VBVMR_Login()
if ($rc -lt 0) { Log "FATAL: Login rc=$rc"; exit 1 }
if ($rc -eq 1) {
    # Step 1 already confirmed the process is running, so rc=1 here means the
    # API cannot see it: almost always because this is not the interactive
    # session. Shared memory is session scoped.
    Log "FATAL: Login rc=1, Voicemeeter is running but not visible from this session."
    Log "  A scheduled task must be set to 'run only when user is logged on'."
    exit 1
}
Start-Sleep -Milliseconds 1500
$drained = $false
for ($i = 0; $i -lt 60; $i++) {
    if ([VMR]::VBVMR_IsParametersDirty() -eq 0) { $drained = $true; break }
    Start-Sleep -Milliseconds 100
}
if (-not $drained) { Log "dirty flag never drained, sets would be ignored"; exit 2 }

# --- 3. A1 must point at a device that EXISTS -------------------------------
# Checking for empty is not enough. The common real-world case is a STALE A1:
# a device name left over from hardware that has since been removed. Voicemeeter
# keeps showing it, refuses to run the audio engine, and reports no error, so
# everything below would appear to succeed while transmitting nothing.
#
# So compare against the devices Voicemeeter can actually see right now.
function Get-OutputDevices {
    $list = @()
    $n = [VMR]::VBVMR_Output_GetDeviceNumber()
    for ($i = 0; $i -lt $n; $i++) {
        $t = 0
        $nm = New-Object System.Text.StringBuilder 512
        $hw = New-Object System.Text.StringBuilder 512
        if ([VMR]::VBVMR_Output_GetDeviceDescA($i, [ref]$t, $nm, $hw) -eq 0) {
            $list += $nm.ToString()
        }
    }
    return $list
}

$devices = Get-OutputDevices
$a1 = GetS "Bus[0].device.name"

if ([string]::IsNullOrWhiteSpace($a1) -or ($devices -notcontains $a1)) {
    if ($A1Device -like "REPLACE*") {
        Log "FATAL: A1 is '$a1' which is not an available device, and `$A1Device is not set."
        Log "  Run list-devices.ps1 and set `$A1Device to one of the names it prints."
        exit 1
    }
    if ($devices -notcontains $A1Device) {
        Log "FATAL: `$A1Device ('$A1Device') is not an available output device."
        Log "  Run list-devices.ps1 for the exact strings. Do not include a 'WDM:' prefix."
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($a1)) {
        Log "A1 is empty, setting to '$A1Device' and restarting engine"
    } else {
        Log "A1 invalid ('$a1' is not an available device), repointing to '$A1Device' and restarting engine"
    }
    [VMR]::VBVMR_SetParameterStringA("Bus[0].device.wdm", $A1Device) | Out-Null
    Start-Sleep -Milliseconds 500
    [VMR]::VBVMR_SetParameterFloat("Command.Restart", 1) | Out-Null
    exit 2
}

# --- 4. apply ---------------------------------------------------------------
# NOTE: this unconditionally takes over VBAN outgoing stream slot 0. If you
# already use slot 0 for something else, change every "outstream[0]" below to a
# free slot.
foreach ($b in @("A1","A2","A3","B1","B2")) {
    [VMR]::VBVMR_SetParameterFloat("Strip[$StripIndex].$b", 0) | Out-Null
}
[VMR]::VBVMR_SetParameterFloat("Strip[$StripIndex].$busName", 1) | Out-Null
[VMR]::VBVMR_SetParameterFloat("Strip[$StripIndex].mute", 0) | Out-Null
[VMR]::VBVMR_SetParameterFloat("Strip[$StripIndex].gain", 0) | Out-Null
[VMR]::VBVMR_SetParameterFloat("Bus[$BusIndex].mute", 0) | Out-Null
[VMR]::VBVMR_SetParameterFloat("Bus[$BusIndex].gain", 0) | Out-Null

if ([int](GetF "vban.outstream[0].sr") -ne $SampleRate) {
    [VMR]::VBVMR_SetParameterFloat("vban.outstream[0].on", 0) | Out-Null
    Start-Sleep -Seconds 2
    [VMR]::VBVMR_SetParameterFloat("vban.outstream[0].sr", $SampleRate) | Out-Null
    Start-Sleep -Seconds 2
}

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

# --- 5. verify, because a Set returning success proves nothing ---------------
$bad = @()
if ((GetS "vban.outstream[0].ip")             -ne $HubIp)      { $bad += "ip" }
if ([int](GetF "vban.outstream[0].port")      -ne $HubPort)    { $bad += "port" }
if ([int](GetF "vban.outstream[0].sr")        -ne $SampleRate) { $bad += "sr" }
if ([int](GetF "vban.outstream[0].route")     -ne $BusIndex)   { $bad += "route" }
if ([int](GetF "vban.outstream[0].on")        -ne 1)           { $bad += "on" }
if ([int](GetF "vban.Enable")                 -ne 1)           { $bad += "enable" }
if ([int](GetF "Strip[$StripIndex].$busName") -ne 1)           { $bad += "strip.$busName" }

if ($bad.Count -eq 0) {
    Log ("OK - '{0}' -> {1}:{2} sr={3} route={4}" -f $StreamName, $HubIp, $HubPort, $SampleRate, $BusIndex)
    [VMR]::VBVMR_Logout() | Out-Null
    exit 0
}

Log ("did not take: " + ($bad -join ", "))
[VMR]::VBVMR_Logout() | Out-Null
exit 2
