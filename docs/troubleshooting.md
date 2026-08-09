# Troubleshooting

Almost every failure here is silent. Nothing crashes, no error appears, you just
get no sound. So work along the chain in order rather than guessing.

## Find out where it stops

There are four links. Test them in this order, because each one rules out
everything before it.

### 1. Are packets leaving the sender and arriving at the hub?

On the hub:

```bash
sudo tcpdump -i any -n 'udp port 10001' -c 20      # Roc sender
sudo tcpdump -i any -n 'udp port 6980'  -c 20      # VBAN sender
```

Play something on the sender while that runs.

A steady stream of packets means the network is fine and the problem is on the
hub. Nothing at all means the sender is not transmitting, or a firewall is in the
way. Note that a VBAN sender transmits continuously once enabled, even in silence,
so with VBAN you should see packets whether or not anything is playing.

### 2. Are the hub's ports actually bound?

```bash
ss -uln | grep -E ':(6980|6981|10001|10003) '
```

Nothing listed means a receiver module did not load.

```bash
journalctl --user -u pipewire-audio-hub | grep -iE 'err|fail'
```

**If that comes back empty, check your log level before concluding there are no
errors.** `log.level = 0` in the config disables logging entirely, including
errors, and an empty journal then looks exactly like a clean one. The shipped
example uses `log.level = 2`.

The Roc repair port being absent is normal and expected when `fec.code = disable`.

### 3. Is the receiver decoding?

```bash
pw-top -b -n 4 | grep -E 'hub-'
```

A node in state `R` with a non zero rate and a real processing time is decoding
audio. Zeros across the board mean packets are arriving but nothing is being turned
into sound, which usually means a protocol mismatch. See the FEC and sample rate
sections below.

Take several samples, which is why this uses `-n 4`. The first reading or two are
often captured before the stream establishes and show zeros even when everything is
working, which is an easy way to misdiagnose a healthy sender.

### 4. Is it routed to the right sink?

```bash
pw-link -l | grep -A1 '^hub-'
```

Grep on your own `node.name` prefix rather than on port names like `receive_FL`,
which vary between versions. If that returns nothing you cannot tell whether the
plumbing is broken or your grep is wrong.

Each receiver should be linked to the sink you expect. If it is linked to the wrong
one, there are two possibilities, and the next check tells them apart:

```bash
pactl list short sinks | cut -f2 | grep -qxF 'THE_NAME_FROM_YOUR_CONFIG' && echo present
```

If the name is **absent**, `target.object` is missing or misspelled. If it is
**present**, the config is right and the pin was never resolved at start; see
[One destination plays out of another destination's hardware](#one-destination-plays-out-of-another-destinations-hardware).

## Common causes

### The whole PipeWire session keeps restarting

A module failed to load and took the context with it. Check for `could not load
mandatory module` in the journal.

The usual cause is `fec.code = rs8m` on a build of libroc without OpenFEC. Set it
to `disable`.

Add `flags = [ ifexists nofail ]` to every module so this cannot happen again.

### Packets arrive, receiver shows no activity, no errors anywhere

Almost always a FEC mismatch. The sender's source URI scheme and the receiver's
`fec.code` have to agree:

| Hub `fec.code` | Sender source URI | Repair endpoint |
|---|---|---|
| `disable` | `rtp://` | none |
| `rs8m` | `rtp+rs8m://` | `rs8m://` |

Check what the hub actually supports:

```bash
ldd /lib/*/libroc.so* | grep -i fec
```

### Audio plays but sounds slow, deep, or chipmunk-like

Sample rate mismatch on a VBAN stream. PipeWire's VBAN receiver uses its
**configured** `audio.rate`, not the rate in the packet header, so mismatched ends
do not fail, they just play at the wrong speed.

Set `audio.rate` on the hub receiver and `SR` in Voicemeeter to the same value.

Roc negotiates properly and does not have this failure mode.

### Windows: no packets at all, Voicemeeter looks configured

Check that the **A1** hardware output points at a device that exists. Voicemeeter
does not run its audio engine without a valid A1, and it sends nothing, silently. A
device name shown in red in the Voicemeeter interface means it could not be opened.

This most often happens on a machine whose audio hardware changed after Voicemeeter
was first set up.

### Windows: two PCs, one of them garbled

Two VBAN senders pointed at the same hub port. The PipeWire receiver in current
stable releases cannot separate senders by stream name, so both streams interleave.
Give each sender its own port and its own receiver instance.

Roc does not have this limitation, and mixes multiple senders on one port fine.

### Windows: it worked, then I closed Voicemeeter and now nothing works

Closing the window exits Voicemeeter rather than minimising it, unless **System
Tray (Close = Hide)** is enabled in its Menu. Reopening it does not help, because
Voicemeeter only writes settings on a clean exit and does not reliably do so, so it
restarts with defaults: VBAN off, no IP, no routing, and an A1 output that may not
exist.

Double click the **"Start Audio Hub"** desktop shortcut if you installed it, or run
`apply-vban.ps1` again. Then enable the System Tray setting so it stops happening.

### Windows: settings do not stick

If you are using the Remote API, you must poll `VBVMR_IsParametersDirty()` until it
returns 0 after logging in. Set calls made before that return success and do
nothing. This is the single most confusing behaviour in that API.

If you are using the GUI, remember Voicemeeter saves on clean exit. Killing the
process loses changes.

### macOS: connect is rejected as an invalid endpoint

The device was created with FEC enabled (the default) and you gave it a plain
`rtp://` source. Recreate it:

```bash
roc-vad device del <INDEX>
roc-vad device add sender --name "Hub Speakers" --fec-encoding disable
```

### macOS: the installer said it failed

It usually did not. See [sender-macos.md](sender-macos.md). Check whether the two
installed paths exist before believing the message.

### Nothing works after a reboot, before anyone logs in

Expected unless you did the lingering setup in
[hub-linux.md](hub-linux.md#6-make-it-start-at-boot). The three requirements are
lingering enabled, the user in the `audio` group, and config plus unit plus enable
symlink all outside an encrypted home directory.

### No sound from a powered speaker, and everything on the hub looks correct

Before investigating the computer at all, check **which input the speaker is
listening on**, not just that it is powered on with a cable in it. Powered speakers
and soundbars commonly have aux, optical, Bluetooth and USB inputs, and selecting
the wrong one produces exactly this: total silence, no error, and a hub that looks
perfectly healthy end to end.

This is worth ruling out first because it is free, and because the alternative is a
long detour into codec pin maps and port priorities. "It's on and the cable is in"
is not the same as "it is listening to that cable".

Verify the hub side is doing its job with:

```bash
pw-top -b -n 4 | grep hub-       # receiver decoding?
pactl list sinks | grep -E 'Active Port|Mute:'
```

If audio is reaching the sink and the port is unmuted, the fault is downstream of
the computer.

### One destination plays out of another destination's hardware

Symptom: a destination comes out of the wrong **device** entirely, and does so for
every sender at once. On a two destination hub, "speakers" arrives at the
headphones, or the reverse.

Suspect the hub, not the senders. Windows senders use VBAN and macOS senders use
Roc, so if both are wrong in the same way, the only shared element is the hub.

The mechanism is a `target.object` pin that was never resolved. If a receiver
starts while its pinned sink does not exist, the session manager falls back to
the **default sink** and never moves the stream back. The receivers are healthy,
the ports are bound, the service is `active`, and the audio is simply going
somewhere else. Nothing is logged at the shipped `log.level`.

Establish it in three steps. First, what the config asks for against what is
actually linked:

```bash
# what the config pins
grep -E 'node.name|target.object' /etc/pipewire/audio-hub.conf

# what is actually linked
pw-link -l | grep -A1 '^hub-'
```

Second — and this is the step that distinguishes a fallback from a simple typo —
check the pinned name exists right now:

```bash
pactl list short sinks
```

If the pinned name is **absent**, you have a bad name, not a fallback. If it is
**present** while the link points elsewhere, that is the fallback.

A suspended sink corroborates it: a sink nothing is routed to sits `SUSPENDED`,
so a destination that should be playing while its sink is suspended is consistent
with the audio going elsewhere. Consistent, not conclusive — a sink is also
suspended when the sender simply is not transmitting.

The immediate fix is to restart the hub once the devices are all present:

```bash
systemctl --user restart pipewire-audio-hub
```

**A single destination hub cannot show you this.** When the only pinned sink is
also the default sink, a receiver that fell back looks identical to one that was
pinned correctly, because both end up in the same place. The fault stays
invisible until a second destination exists, and then it affects everything at
once. Do not conclude a receiver is pinned correctly just because it sounds
right; check the link.

To stop it recurring at boot, see
[`wait-for-sinks.sh`](../scripts/linux-hub/wait-for-sinks.sh), which holds the
receivers until every pinned sink exists and says so in the journal when one
never turns up.

### Audio plays, but out of the wrong physical output

Symptom: everything arrives at the hub correctly, but comes out an internal
chassis speaker or the wrong jack, and moving the cable does not help.

Different from the previous entry: there the audio went to the wrong **sink**,
here it reaches the right sink and leaves by the wrong **port**.

This is port selection, not routing. Check which port the sink is using:

```bash
pactl list sinks | sed -n '/Name: YOUR_SINK_NAME/,/^Sink #/p' | grep -E 'Active Port|analog-output-'
```

If the port you want says **not available** even with a cable in it, reseat the
cable first. A plug that is not fully home reports identically to a dead jack, and
that is a much more common explanation than broken detection. When a cable is
properly seated on a working jack, the port flips to `available` immediately and the
session manager usually selects it on its own with no intervention.

If it still says **not available** with the cable firmly seated, then detection on
that board is genuinely unreliable. PipeWire falls back to the highest priority port
it thinks is usable, and an internal speaker typically outranks line out (priority
10000 against 9000).

Force it:

```bash
pactl set-sink-port YOUR_SINK_NAME analog-output-lineout
```

**Restart the hub afterwards.** Changing a sink's port after the receivers have
linked kills the `vban-recv` streams permanently. They vanish from the graph rather
than reconnecting, and the service starts burning CPU spinning on the dead modules.
Roc receivers survive it.

```bash
systemctl --user restart pipewire-audio-hub
pw-link -l | grep -A1 '^hub-'     # confirm all receivers came back
```

That fix is runtime only. To make it survive a reboot, especially on an encrypted
home where the session manager cannot read its saved state before login, see
[`force-output-port.service.example`](../scripts/linux-hub/force-output-port.service.example).

### Receivers disappear from the graph

If `pw-cli ls Node` shows fewer receivers than you configured, and the service is
still "active", something reconfigured a target sink underneath them. Changing a
sink port does this, as does a device being unplugged.

`vban-recv` streams die permanently in that situation. Restarting the hub rebuilds
them. If a receiver's `target.object` names a device that no longer exists, that
receiver will keep failing until the device returns or you point it elsewhere.

### Audible dropouts and gaps

Usually the network. Check the hub is on wired ethernet.

If a sender must be on Wi-Fi, raise `sess.latency.msec` on that receiver, prefer Roc
over VBAN since VBAN has no loss recovery at all, and confirm nothing is using
multicast.

A quick sanity check on link quality, from a sender:

```bash
ping -c 20 HUB_IP
```

On a healthy wired LAN expect low single digit milliseconds and very little
variation. Tens of milliseconds with large swings will cause dropouts, since the
jitter exceeds the receiver buffer. On laptops the usual culprit is Wi-Fi power
saving, which can produce terrible latency even with a strong signal.

## Useful commands

```bash
# what receivers exist and what they are doing
pw-top -b -n 4

# exact sink names for target.object
pactl list short sinks

# per source volume control
pavucontrol

# what the module actually supports on YOUR version
man 7 libpipewire-module-roc-source
man 7 libpipewire-module-vban-recv
```

That last one is worth repeating. Option names have changed between PipeWire
releases, and the manpage on the machine is authoritative where the website may
describe a version you do not have.
