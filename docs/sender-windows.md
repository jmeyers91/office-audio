# Windows sender setup

Windows reaches the hub over VBAN, because Roc has no Windows port.

The end result is an ordinary output device in your sound settings, which you can
rename to whatever you like. Select it and that machine's audio comes out of the
hub. Select your normal device and everything goes back to local.

## What you are installing and why

**Voicemeeter** is a virtual audio mixer from VB-Audio. Installing it adds virtual
sound cards to Windows, which applications can play into like any other device.
Voicemeeter takes whatever arrives on those virtual cards and routes it wherever
you tell it, including out over VBAN to another machine.

That indirection is the whole reason it is here. Windows has no built in way to
send system audio over a network, and Voicemeeter is the most established tool that
provides both a virtual output device and a network sender.

The main tradeoff compared to the macOS setup: **Voicemeeter has to be running**.
It is an application, not just a driver. Autostart is covered at the end.

Get it from [vb-audio.com/Voicemeeter](https://vb-audio.com/Voicemeeter/). It is
donationware. Install **Banana** rather than the standard edition. Banana provides
two virtual inputs, so you can dedicate one to the hub and leave the other free for
normal use. Reboot after installing.

## How Voicemeeter is organised

Worth understanding before you click anything, because the terminology is its own.

- **Strips** are inputs, arranged as columns. The left ones are physical inputs
  (microphones). The right ones are the **virtual inputs**, which is where audio
  from Windows applications arrives. Banana has two, named VAIO and AUX.
- **Buses** are outputs: A1, A2, A3 are physical outputs, B1 and B2 are virtual
  outputs. Each strip has a row of buttons choosing which buses it feeds.
- **VBAN streams** take a bus and send it over the network.

So the path is: Windows application, into a virtual input strip, routed to a bus,
and that bus goes out as a VBAN stream.

The plan is to dedicate the **AUX** virtual input to the hub, route it to **B2**
and nothing else, and send B2 out over VBAN. Because AUX feeds no physical output,
selecting it in Windows sends audio only to the hub, and your normal speakers stay
untouched.

## If you have more than one Windows PC

Read this before step 3, because getting it wrong produces garbled audio rather
than an error.

Each Windows machine needs **its own port on the hub**, and its own `vban-recv`
block in the hub config. The PipeWire VBAN receiver cannot separate two senders
arriving on one port, so they interleave into noise.

| Windows PC | Hub port, destination 1 | Hub port, destination 2 |
|---|---|---|
| first | 6980 | 6990 |
| second | 6981 | 6991 |

Everything else on each machine is identical. Set up the first PC completely, then
repeat on the second and change only the port: in the VBAN dialog in step 3, or
`$HubPort` in `apply-vban.ps1` if you are scripting it.

Roc has no such limitation, which is why Linux and macOS senders all share one port
and only Windows needs this.

## If you want more than one hub destination

If the hub exposes two destinations, for example headphones and speakers, one
Windows machine can reach both. Each destination needs its own virtual input, its
own bus, and its own VBAN stream.

Banana has two virtual inputs, which is exactly enough for two destinations:

| Windows device | Voicemeeter strip | Bus | VBAN slot | Hub port |
|---|---|---|---|---|
| VoiceMeeter Aux Input | Strip 5 (AUX), index 4 | B2 | 0 | 6990 |
| VoiceMeeter Input | Strip 4 (VAIO), index 3 | B1 | 1 | 6980 |

Rename both in Windows and you get two ordinary output devices to switch between.

Two things to watch. Each strip must feed **only** its own bus, or audio meant for
one destination leaks into the other. And the hardware input strips default to
routing to B1, so clear B1 on those or a connected microphone ends up in your
headphones stream. The bundled script does both.

If you need three destinations you need Voicemeeter Potato, which has a third
virtual input.

## 1. Give A1 a real device

Do this first. It is the single most common reason nothing works.

Voicemeeter will not run its audio engine at all unless the **A1** output points at
a device that actually exists. If A1 is empty or points at hardware that has since
been removed, the whole mixer sits idle and your VBAN stream transmits nothing,
with no error message anywhere.

The stale case is the common one. It bites people who installed Voicemeeter once,
months ago, on a machine whose audio hardware has changed since. Voicemeeter keeps
displaying the old name quite happily. A device name shown in **red** in the
interface means it could not be opened.

Click the **A1** button at the top right and pick any real output. It does not have
to be one you use. Nothing is routed to A1 in this setup, so it only ever receives
silence. A monitor's HDMI audio output is a good throwaway choice.

Prefer a **WDM** entry unless you have a reason not to.

If you are scripting this, run
[`list-devices.ps1`](../scripts/windows-sender/list-devices.ps1) to print the exact
device strings and to say whether your current A1 is valid, empty, or stale. Note
that Voicemeeter's menu displays entries with a `WDM:` prefix but the API does not
want it, so copy from that script rather than from the menu.

## 2. Route the AUX strip to B2 only

Find the AUX virtual input strip. On its bus buttons, turn **B2 on** and turn
**A1, A2, A3 and B1 all off**.

Optionally click the strip's name label and rename it, which just makes the mixer
easier to read later.

## 3. Configure the VBAN stream

Click **VBAN** in the top bar to open the network dialog, and fill in the first row
under **Outgoing Streams**:

| Field | Value |
|---|---|
| On | enabled |
| Stream Name | anything, for example `HubOutput` |
| IP Address | the hub's address |
| Port | the hub port for this PC and destination, see the table above |
| SR | must match the hub's `audio.rate` |
| Channels | 2 |
| Bit | 16 |
| Quality | 1 is a reasonable default |
| Source | **Bus B2** |

Two of these matter more than they look.

**SR must match the hub.** PipeWire's VBAN receiver uses its configured rate, not
the rate in the packet header. If they disagree the audio plays at the wrong speed
and pitch rather than failing. The example hub config uses 44100.

**Source must be the bus you routed AUX to**, B2 in this guide. If it points at a
different bus you will get either silence or the wrong machine's audio.

The stream name is only a label here. The PipeWire receiver in current stable
releases does not filter on it, which is exactly why each Windows machine needs its
own port rather than its own stream name.

## 4. Rename the Windows device

Windows now has a playback device called **VoiceMeeter Aux Input**. Rename it to
something meaningful.

Press **Win+R** and run `mmsys.cpl`. That opens the classic Sound control panel
directly on both Windows 10 and 11, which saves hunting: on Windows 11 it is buried
under Settings, System, Sound, More sound settings.

Playback tab, right click **VoiceMeeter Aux Input**, Properties, change the name,
Apply.

Now it reads like a real device, for example "Hub Speakers".

## 5. Test

Set that device as your output and play something. Audio should come out of the
hub.

If it does not, check from the hub that packets are arriving before touching
anything on Windows:

```bash
sudo tcpdump -i any -n 'udp port 6980' -c 20
```

Steady packets mean Windows is transmitting and the problem is on the hub side. No
packets means Voicemeeter is not sending, and A1 (step 1) is the first thing to
re-check. See [troubleshooting](troubleshooting.md).

## 6. Stop closing the window from breaking everything

Do this before you forget. By default, clicking the X on Voicemeeter's window does
not minimise it, it **exits the application**. Two things then happen:

1. The virtual device stops working, because nothing is routing it any more.
2. Reopening Voicemeeter does **not** fix it. Voicemeeter only writes its settings
   on a clean exit and does not reliably do so, so it comes back with defaults:
   VBAN off, no IP, no routing, and an A1 output pointing at whatever it
   originally guessed.

Open the **Menu** in the top bar and set:

- **System Tray (Close = Hide)**: on
- **Show App On Startup**: off

Now closing the window sends it to the tray instead of killing it, and it does not
open a window every time you log in.

## 7. Autostart and a recovery button

Voicemeeter has to be running for the device to work. There are two ways to
arrange that, and they do not mix.

### Option A: let Voicemeeter do it

Menu, then **Run on Windows Startup**: on. Simplest, but it depends on Voicemeeter
having saved your configuration, which is the part that is not dependable.

### Option B: drive it from a script

This repo includes a script that applies the whole configuration through
Voicemeeter's Remote API, so it does not matter whether Voicemeeter remembered
anything.

**Put the repo somewhere permanent first**, for example `C:\Tools\office-audio`.
The logon task and the desktop shortcut both record the path they were installed
from, so if you run them out of `Downloads\` and later clear it out, your autostart
dies silently months later.

Then unblock the files. Anything extracted from a downloaded zip carries the mark
of the web, and PowerShell's default execution policy will refuse it:

```powershell
cd C:\Tools\office-audio
Get-ChildItem -Recurse | Unblock-File
```

Edit the settings block at the top of
[`apply-vban.ps1`](../scripts/windows-sender/apply-vban.ps1). Use
[`list-devices.ps1`](../scripts/windows-sender/list-devices.ps1) to get the exact
`$A1Device` string. Then:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows-sender\install-task.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\windows-sender\install-shortcut.ps1
```

The first applies the config at every logon. The second creates the desktop
recovery button.

The **"Start Audio Hub"** desktop icon can be double clicked any time the Windows
side stops working, including after an accidental close. It starts Voicemeeter if
needed, applies everything, verifies it, and shows a confirmation that dismisses
itself.

If you use Option B, **do not also enable Voicemeeter's own "Run on Windows
Startup"**. Voicemeeter is single instance, so the second launch just pops the
window open. Leave the System Tray settings from step 6 as they are.

### What to expect when you run it

A cold start takes roughly 30 to 45 seconds and several internal passes. That is
normal and by design. A typical log looks like:

```
18:00:56  Voicemeeter not running, starting it
18:01:05  A1 invalid ('Speakers (Old Sound Card)' is not an available device), repointing to 'Display Audio (NVIDIA High Definition Audio)' and restarting engine
18:01:20  did not take: ip, port, sr, route, on, enable, strip.B2
18:01:30  OK - 'HubOutput' -> 192.0.2.10:6980 sr=44100 route=4
```

The third line is not an error. Writes made while the audio engine is restarting
are silently discarded by Voicemeeter, so the runner verifies its work and goes
around again. Only a line starting `OK -` means the configuration actually landed.

Logs are at `%LOCALAPPDATA%\office-audio\apply-vban.log`.

## Remote API notes

Anyone extending the script should know these. All of them cost real debugging time
to discover, and all of them fail silently.

- **Drain the dirty flag before setting anything.** After `VBVMR_Login()` you must
  poll `VBVMR_IsParametersDirty()` until it returns 0. Set calls made before that
  return success and do nothing.
- **Writes during an audio engine restart are discarded.** After
  `Command.Restart`, give it well over ten seconds, and verify rather than assume.
  Doing the restart and the configuration in one process is unreliable; a fresh
  process per pass is not.
- **A Set returning success proves nothing.** Always read the value back.
- **The API only works from the interactive session.** It uses session scoped
  shared memory, so a task set to "run whether user is logged on or not" cannot see
  Voicemeeter at all. `VBVMR_Login()` returns 1 rather than 0 in that case.
- **`vban.outstream[N].sr` cannot be changed while the stream is on.** Set `.on` to
  0, change the rate, then set `.on` back to 1.
- **`Command.Shutdown` returns success without closing the application.**

The `route` parameter on an outgoing stream selects the source bus by index. For
Banana the buses are A1, A2, A3, B1, B2, so B2 is `4`.

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName "OfficeAudioHub" -Confirm:$false
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) "Start Audio Hub.lnk")
Remove-Item "$env:LOCALAPPDATA\office-audio" -Recurse
```

Then in Voicemeeter, set the VBAN outgoing stream back to off, or just uninstall
Voicemeeter entirely from Settings, Apps.

Two things to know if you uninstall Voicemeeter: it needs a reboot to fully remove
its virtual sound cards, and if you renamed the device in step 4 that rename is
stored per device in Windows, so it disappears with the device. If you had set
"VoiceMeeter Aux Input" as your default output, set your real output back first,
otherwise Windows picks one for you and it may not be the one you want.

## Next

- [Troubleshooting](troubleshooting.md)
- [Linux hub setup](hub-linux.md)
