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

The Roc repair port being absent is normal and expected when `fec.code = disable`.

### 3. Is the receiver decoding?

```bash
pw-top -b -n 2 | grep -E 'hub-'
```

A node in state `R` with a non zero rate and a real processing time is decoding
audio. Zeros across the board mean packets are arriving but nothing is being turned
into sound, which usually means a protocol mismatch. See the FEC and sample rate
sections below.

Take several samples (`-n 4` rather than `-n 2`). The first reading or two are
often captured before the stream establishes and show zeros even when everything is
working, which is an easy way to misdiagnose a healthy sender.

### 4. Is it routed to the right sink?

```bash
pw-link -l | grep -A1 receive_FL
```

Each receiver should be linked to the sink you expect. If it is linked to the wrong
one, `target.object` is missing or has the wrong node name.

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
pw-top -b -n 2

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
