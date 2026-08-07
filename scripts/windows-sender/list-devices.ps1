# Prints the output devices Voicemeeter can see, so you can copy the exact
# string for $A1Device in apply-vban.ps1.
#
# Voicemeeter's A1 menu displays entries with a "WDM:" / "MME:" / "KS:" prefix.
# The API does NOT want the prefix. This prints the strings the API actually
# expects, so copy from here rather than from the menu.
#
# Voicemeeter must be running, and this must run in your interactive session.

$RemoteDll = "C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll"

if (-not (Test-Path $RemoteDll)) { throw "VoicemeeterRemote64.dll not found at $RemoteDll" }
if (-not (Get-Process -Name "voicemeeterpro","voicemeeter" -ErrorAction SilentlyContinue)) {
    throw "Voicemeeter is not running. Start it first."
}

$src = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VMRL {
  const string DLL = @"$RemoteDll";
  [DllImport(DLL)] public static extern int VBVMR_Login();
  [DllImport(DLL)] public static extern int VBVMR_Logout();
  [DllImport(DLL)] public static extern int VBVMR_IsParametersDirty();
  [DllImport(DLL)] public static extern int VBVMR_Output_GetDeviceNumber();
  [DllImport(DLL)] public static extern int VBVMR_Output_GetDeviceDescA(int i, ref int type, StringBuilder name, StringBuilder hwid);
  [DllImport(DLL)] public static extern int VBVMR_GetParameterStringA([MarshalAs(UnmanagedType.LPStr)] string p, StringBuilder s);
}
"@
if (-not ([System.Management.Automation.PSTypeName]'VMRL').Type) {
    Add-Type -TypeDefinition $src -Language CSharp
}

$rc = [VMRL]::VBVMR_Login()
if ($rc -eq 1) { throw "Login rc=1: Voicemeeter is running but not visible from this session." }
Start-Sleep -Milliseconds 1200
for ($i = 0; $i -lt 40; $i++) { if ([VMRL]::VBVMR_IsParametersDirty() -eq 0) { break }; Start-Sleep -Milliseconds 100 }

$current = New-Object System.Text.StringBuilder 512
[VMRL]::VBVMR_GetParameterStringA("Bus[0].device.name", $current) | Out-Null

$n = [VMRL]::VBVMR_Output_GetDeviceNumber()
Write-Host ""
Write-Host "Available output devices ($n):"
Write-Host ""
$names = @()
for ($i = 0; $i -lt $n; $i++) {
    $t = 0
    $nm = New-Object System.Text.StringBuilder 512
    $hw = New-Object System.Text.StringBuilder 512
    if ([VMRL]::VBVMR_Output_GetDeviceDescA($i, [ref]$t, $nm, $hw) -eq 0) {
        $kind = switch ($t) { 1 {"MME"} 3 {"WDM"} 4 {"KS"} 5 {"ASIO"} default {"?"} }
        Write-Host ("  [{0,-4}] {1}" -f $kind, $nm.ToString())
        $names += $nm.ToString()
    }
}

Write-Host ""
Write-Host "Current A1: '$($current.ToString())'"
if ([string]::IsNullOrWhiteSpace($current.ToString())) {
    Write-Host "  -> A1 is EMPTY. The audio engine will not run until it is set."
} elseif ($names -notcontains $current.ToString()) {
    Write-Host "  -> A1 is STALE: that device is not in the list above."
    Write-Host "     Voicemeeter will not run its audio engine, and will not tell you."
} else {
    Write-Host "  -> A1 is valid."
}
Write-Host ""
Write-Host "Copy a WDM entry above into `$A1Device in apply-vban.ps1 (no prefix)."

[VMRL]::VBVMR_Logout() | Out-Null
