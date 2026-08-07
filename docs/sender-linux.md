# Linux sender setup

A Linux machine sends to the hub using Roc, the same protocol macOS uses. This is
the easiest of the three senders: PipeWire already ships the module, so there is
nothing to install and no application that has to keep running.

The result is an extra output device in your sound settings. Pick it and that
machine's audio goes to the hub. Pick your local device and everything goes back to
normal.

## How it differs from the hub

The hub guide goes to some trouble to avoid `pipewire.conf.d`, because receiver
modules loaded there start before the session manager has created any sink, then
fail permanently with `no target node available`.

A sender does not have that problem. `module-roc-sink` creates a **virtual sink**,
which does not depend on any other node existing, so the ordinary config directory
works fine. No systemd unit, no client context, no lingering.

## 1. Check the module is there

```bash
ls /usr/lib/*/pipewire-0.3/libpipewire-module-roc-sink.so
```

Present on most current distributions. If it is missing, look for a `libroc` or
`roc-toolkit` package.

## 2. Check whether your Roc build has FEC

Same check as the hub, and it has to give the same answer on both machines.

```bash
ldd /lib/*/libroc.so* 2>/dev/null | grep -i fec || echo "no openfec"
```

If neither end has FEC, use `fec.code = disable` and leave `remote.repair.port`
out of the config entirely. If both ends have it, use `fec.code = rs8m` and set the
repair port. Do not mix them. A mismatch produces silence with no error on either
side.

## 3. Add the sender config

Copy [`scripts/linux-sender/roc-sender.conf.example`](../scripts/linux-sender/roc-sender.conf.example)
to `~/.config/pipewire/pipewire.conf.d/roc-sender.conf` and edit the address and
ports.

```bash
mkdir -p ~/.config/pipewire/pipewire.conf.d
cp scripts/linux-sender/roc-sender.conf.example \
   ~/.config/pipewire/pipewire.conf.d/roc-sender.conf
$EDITOR ~/.config/pipewire/pipewire.conf.d/roc-sender.conf
```

The minimum you need to change is `remote.ip`, the two ports, and
`node.description`, which is the name you will see in your sound settings.

Keep `flags = [ ifexists nofail ]`. Without it a mistake in this file takes down
your whole PipeWire session rather than just skipping the module, and you get no
audio at all until you find the typo.

## 4. Restart PipeWire

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
```

Your audio will cut out for a second. Then:

```bash
pactl list short sinks
```

Your new device should be listed. Confirm the friendly name came through:

```bash
pactl list sinks | grep -E 'Name:|Description:'
```

A `mod.jackdbus-detect: Failed to receive jackdbus reply` line in the journal is
unrelated and harmless on machines without JACK installed.

## 5. Use it

The device now appears in your desktop's sound settings alongside the local
outputs. Select it and audio goes to the hub. Per application routing works too, so
`pavucontrol` can send one application to the hub while everything else stays
local.

To test from the command line without changing your default:

```bash
pw-play --target=<sink name> /usr/share/sounds/alsa/Front_Center.wav
```

## Multiple destinations

If the hub exposes more than one output, add a second module block pointing at the
other port pair. Each becomes its own device.

```
local sink name          hub ports
hub-headphones           10001 source, 10003 control
hub-speakers             10011 source, 10013 control
```

The example config includes a second block, commented out.

## Persistence

Nothing else to do. Config in `pipewire.conf.d` is read when PipeWire starts, which
happens when you log in, so the device is there every session.

The one case that needs more work is a machine that has to stream before anybody
logs in, which is unusual for a sender. If you need that, the lingering and
encrypted home notes in the [hub guide](hub-linux.md#6-make-it-start-at-boot) apply
here too.

## Verifying from the hub

If you get no sound, check whether packets are arriving before touching the sender
config:

```bash
sudo tcpdump -i any -n 'udp port 10011' -c 20
```

Then check the receiver is actually decoding rather than just receiving:

```bash
pw-top -b -n 4 | grep hub-
```

Look for the node in state `R` with a non zero rate and a real processing time.
Sample it a few times, because the first reading or two can be taken before the
stream establishes and will show zeros even when everything is fine.

## Next

- [Troubleshooting](troubleshooting.md)
- [Linux hub setup](hub-linux.md)
