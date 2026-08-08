# Phone sender (Bluetooth)

A phone can play to the hub without any app at all, by connecting to it over
Bluetooth as if it were a speaker. The hub then treats that audio like any other
incoming stream and sends it to whichever output you choose.

This is the only sender that needs no software on the sending device.

## Why not the "proper" way

Roc has an Android app, [Roc Droid](https://f-droid.org/en/packages/org.rocstreaming.rocdroid/),
which would match the rest of this project. Two problems make it a poor fit:

**Android will not let it capture most audio.** Apps can only capture other apps'
playback if the source app permits it, and [apps playing protected content opt
out](https://developer.android.com/media/platform/av-capture). Spotify is one of
them, and capturing it produces silence rather than an error.

**It is a proof of concept**, last released mid-2024.

Bluetooth has none of those problems: it is the phone's normal audio output path,
so everything works, including the apps that block capture.

The tradeoff is that Bluetooth is lossy and range-limited, where Roc and VBAN are
not. For a phone that is usually the right trade.

## One adapter per visible device

This is the constraint that shapes everything.

**A Bluetooth adapter has exactly one address, so it can only ever appear as one
device in your phone's list.** If you want the phone to offer a choice between two
hub outputs, you need two adapters. One adapter happily handles multiple
simultaneous *connections*, but it cannot present two *identities*.

So:

- One adapter: the phone sees one device, and the hub decides where it plays.
- Two adapters: the phone sees two devices and you pick on the phone.

## 1. Configure the hub as an A2DP sink

Create `/etc/wireplumber/bluetooth.lua.d/51-bluetooth-a2dp-sink.lua` from
[the example](../scripts/linux-hub/51-bluetooth-a2dp-sink.lua.example).

Two settings matter, and both were found the hard way:

```lua
bluez_monitor.properties["bluez5.roles"] = "[ a2dp_sink ]"
bluez_monitor.properties["bluez5.hfphsp-backend"] = "none"
```

**`a2dp_sink` only.** Adding `a2dp_source` looks reasonable, since the phone *is* a
source, and it breaks everything: the phone still connects but no audio node is ever
created. Do not add it.

**HFP/HSP off.** Offering the Hands-Free roles causes connections to come up and
immediately drop, with the phone showing "Connected" then falling back to "Saved".
The log shows:

```
Unable to get io data for Hands-Free unit: getpeername:
Transport endpoint is not connected (107)
```

A failed HFP negotiation tears down the whole link and takes A2DP with it. You don't
want your hub acting as a speakerphone anyway.

Restart the session manager afterwards. On a hub, that also means restarting the
receivers, since reconfiguring devices underneath them kills the VBAN streams:

```bash
systemctl --user restart wireplumber
systemctl --user restart pipewire-audio-hub
```

## 2. Install a pairing agent

**Do this or nothing will connect.** BlueZ needs an *agent* registered to authorise
incoming connections. Without one, every attempt is refused:

```
Authentication attempt without agent
a2dp.c:auth_cb() Access denied: org.bluez.Error.Rejected
```

A desktop session usually provides one, which is a trap: it works while you are
logged in, then silently stops the moment Bluetooth restarts or you go headless.

```bash
sudo apt install bluez-tools
sudo cp scripts/linux-hub/bt-agent.service /etc/systemd/system/
sudo systemctl enable --now bt-agent
```

`NoInputNoOutput` accepts pairing without a confirmation prompt, because a headless
machine has no way to show one. Combined with leaving the adapter discoverable, that
means anything in range can attempt to pair. On a home network that is usually an
acceptable trade. If it is not, leave the adapter non-discoverable and only enable
discovery while pairing something new.

## 3. Name the adapters

The alias is what your phone displays. Set it in BlueZ's own storage, with
bluetoothd stopped so nothing overwrites it:

```bash
sudo systemctl stop bluetooth
sudo tee /var/lib/bluetooth/AA:BB:CC:DD:EE:FF/settings <<'END'
[General]
Alias=Hub Headphones
Discoverable=true
END
sudo systemctl start bluetooth
```

Get adapter addresses from `hciconfig`.

Two tools that look like they should do this and do not: `btmgmt --index` silently
applies to the wrong adapter, and `bluetoothctl select` followed by commands does
not take effect when piped in as a heredoc. Editing the files is reliable.

To keep it discoverable across reboots, also set in `/etc/bluetooth/main.conf`:

```ini
DiscoverableTimeout = 0
PairableTimeout = 0
AlwaysPairable = true
```

## 4. Pair, and trust

Pair from the phone. Then **mark it trusted**, or BlueZ will not auto-accept the
profile connection and you will get connect-then-immediately-disconnect:

```bash
bluetoothctl trust AA:BB:CC:DD:EE:FF   # the PHONE's address
```

With two adapters, trust it on each one you paired with.

## 5. Route it

By default the audio lands on whatever the default sink happens to be. The Bluetooth
alias is only a name; it carries no routing meaning.

### One adapter

A WirePlumber rule is enough:

```lua
table.insert(bluez_monitor.rules, {
  matches = { { { "node.name", "matches", "bluez_input.*" } } },
  apply_properties = { ["target.object"] = "YOUR_SINK_NAME" },
})
```

### Two adapters

A rule cannot do this, and it is worth knowing why before you try.

**Nothing on the audio node identifies which adapter it arrived on.** `node.name` is
derived from the *phone's* address, and `api.bluez5.transport` is empty even while
streaming. The only route to that information is `device.id`, pointing at a Device
object whose `api.bluez5.path` looks like `/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF`.

Matching that in a rule does not work either: the property applies to the *device*,
and `target.object` has to take effect on the *node*. It does not propagate across
that boundary. Both adapters end up on the same sink.

So use [`bt-audio-router.py`](../scripts/linux-hub/bt-audio-router.py), which
resolves the adapter and moves the stream:

```bash
sudo cp scripts/linux-hub/bt-audio-router.py /usr/local/bin/
sudo cp scripts/linux-hub/bt-audio-router.service /etc/systemd/user/
sudo ln -sf /etc/systemd/user/bt-audio-router.service \
            /etc/systemd/user/default.target.wants/
systemctl --user daemon-reload && systemctl --user start bt-audio-router
```

Edit the `ADAPTER_SINKS` map at the top with your adapter addresses and sink names.

It keys on **adapter MAC, not `hciN`**, because the numbering is not stable. A USB
dongle can move between `hci1` and `hci2` across replugs, and hard-coding the number
gives you routing that silently breaks later.

## Diagnosing bad range

Bluetooth choppiness is usually signal, and it is measurable rather than a matter of
opinion. With the phone connected and left in one place:

```bash
sudo hcitool rssi AA:BB:CC:DD:EE:FF   # phone address
sudo hcitool lq   AA:BB:CC:DD:EE:FF
```

`hcitool rssi` reports the difference from the golden receive range, so **0 is
ideal** and negative is weak. Link quality is out of 255.

A reading like RSSI `-17` with quality `255` means the radio is healthy and the link
is clean but the signal is weak, which is a range or antenna problem rather than
interference.

**Check the antenna before buying anything.** On a desktop with an M.2 combo card,
the antenna leads are frequently left unconnected, or the machine has an external
connector with nothing screwed onto it. In testing, attaching an antenna took a
system from RSSI `-17` to `0`, roughly a fiftyfold improvement, and completely
removed the need for a better radio.

If you do add a USB dongle, put it on a short extension cable rather than flush
against the back panel. Getting the antenna out of a metal chassis usually matters
more than the chipset, and cheap "nano" dongles have very small antennas.

## Troubleshooting

**The card shows an `audio-gateway` profile with `sinks: 0, sources: 0` and there is
no audio node.** That is normal when nothing is playing. The node
(`bluez_input.<phone>.<n>`) exists only while audio is actually streaming. Do not
diagnose anything from the idle state; press play first.

**Everything worked and then stopped for no reason.** Check `rfkill list`. A desktop
Bluetooth applet such as `blueman-applet` re-asserts its own power state and will
soft-block the adapters. If the tray toggle is off it will keep blocking them no
matter what you set from the command line.

**Connections refused after restarting bluetoothd.** The agent is gone. See step 2.

**`/sys/class/bluetooth/<hci>/address` does not exist.** Adapter addresses come from
`hciconfig`, not sysfs.

## Next

- [Troubleshooting](troubleshooting.md)
- [Linux hub setup](hub-linux.md)
