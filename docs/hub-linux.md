# Linux hub setup

The hub is the machine with the speakers or headphones attached. It runs PipeWire
with a set of network receiver modules, and everything those receivers pick up gets
mixed and sent to the audio device you choose.

This guide assumes a desktop Linux install using PipeWire, which covers most
current distributions. It was written against PipeWire 1.0.5 on an Ubuntu 24.04
based system, and it calls out where newer versions differ.

## 1. Check what you have

```bash
pipewire --version

for m in roc-source vban-recv; do
  ls /usr/lib/*/pipewire-0.3/libpipewire-module-$m.so >/dev/null 2>&1 \
    && echo "ok   $m" || echo "MISSING $m"
done
```

Both modules ship with PipeWire on most distributions, so there is usually nothing
to install. If `roc-source` is missing, look for a `libroc` or `roc-toolkit`
package. If `vban-recv` is missing, your PipeWire is probably too old.

You only need `roc-source` if you have macOS or Linux senders, and `vban-recv` only
if you have Windows senders.

## 2. Check whether your Roc build has FEC

This one catches people out, so do it before writing any config.

Roc can recover lost packets using forward error correction, but that requires
libroc to have been compiled with OpenFEC. Several distributions, including the
Ubuntu and Mint packages, build it **without**. If FEC is unavailable and you ask
for it anyway, the module fails to load and takes the whole PipeWire session with
it.

```bash
ldd /lib/*/libroc.so* 2>/dev/null | grep -i fec || echo "no openfec linked"
```

If that prints nothing, your build has no FEC. Use `fec.code = disable` in the
config below, and have every sender use a plain `rtp://` source address with no
repair endpoint. The two must agree. A sender using `rtp+rs8m://` against a
receiver with FEC disabled will produce silence and no useful error.

You can confirm after the fact: with FEC disabled, the repair port never appears in
`ss -uln`, which is expected and not a fault.

Losing FEC only matters on lossy links. On wired ethernet it makes no practical
difference. If you need it and your distribution does not ship it, you would have
to build roc-toolkit from source with `--build-3rdparty=openfec`.

## 3. Write the receiver config

Copy [`scripts/linux-hub/audio-hub.conf.example`](../scripts/linux-hub/audio-hub.conf.example)
to `/etc/pipewire/audio-hub.conf` and edit it. The important decisions are which
ports to listen on and which sink each receiver feeds.

Two things about this file are not obvious, and both cause silent failure.

### Do not put these modules in `pipewire.conf.d`

The natural place for extra modules is `~/.config/pipewire/pipewire.conf.d/`. It
does not work for these. Modules loaded there start inside the PipeWire daemon
context, which comes up *before* the session manager has created any sink. The
receiver streams then fail with `no target node available` and never retry, so you
get a receiver that is permanently dead even though the config looks right.

Instead the modules run as a **client context**: a second PipeWire process that
connects to the daemon like any application, started after the session manager.
This also means the receivers survive the audio device being unplugged and
replugged, which the daemon context version does not.

### Always use `nofail`

```
flags = [ ifexists nofail ]
```

Without this, a single bad option in one module is fatal to the entire context.
PipeWire exits, systemd restarts it, it fails again, and after a few rounds systemd
gives up and you have no audio at all until you find the typo. With `nofail` a
broken module is skipped and everything else still works.

### Pin each receiver to a sink

```
stream.props = {
    target.object = "alsa_output.usb-Example_Interface-00.analog-stereo"
}
```

Get the exact name from `pactl list short sinks`.

You can leave this out, in which case receivers follow the default sink. Pinning is
better for two reasons. It makes routing predictable when you have more than one
destination, and it does not depend on the session manager's saved default, which
lives in the user's home directory and may not be readable at boot. See step 6.

### Match the sample rate for VBAN

PipeWire's VBAN receiver uses the sample rate from its **configuration**, not from
the packet header. If a sender transmits 48000 and the receiver is set to 44100,
audio plays about 8.8 percent slow, at a noticeably lower pitch. Pick one rate and
set it on both ends. The examples here use 44100 because that is what roc-vad
defaults to, which keeps everything consistent.

Roc negotiates properly and does not have this problem.

### A note on option names

On PipeWire 1.0.5 the Roc resampler option is `resampler.profile`. Current online
documentation shows `roc.resampler.profile`, which is a newer name. If a module
refuses to load, check the option names against your installed version:

```bash
man 7 libpipewire-module-roc-source
man 7 libpipewire-module-vban-recv
```

The manpage on the machine is authoritative. The website may describe a version you
do not have.

## 4. Install the service

```bash
sudo cp scripts/linux-hub/audio-hub.conf.example /etc/pipewire/audio-hub.conf
sudo cp scripts/linux-hub/pipewire-audio-hub.service /etc/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now pipewire-audio-hub.service
```

Check it came up:

```bash
systemctl --user is-active pipewire-audio-hub
journalctl --user -u pipewire-audio-hub -n 30
```

## 5. Verify the plumbing

Three things should be true before you try to send anything.

```bash
# receivers exist and are linked to a sink
pw-link -l | grep -A1 receive_FL

# the ports are actually bound
ss -uln | grep -E ':(6980|6981|10001|10003) '

# no errors
journalctl --user -u pipewire-audio-hub | grep -iE 'err|fail'
```

If your firewall is active, open the UDP ports you configured.

```bash
sudo ufw allow 10001:10003/udp
sudo ufw allow 6980:6991/udp
```

## 6. Make it start at boot

For an always on hub you want the receivers running before anyone logs in.

```bash
sudo loginctl enable-linger $USER
```

Two things can stop this working.

**Device permissions.** Access to `/dev/snd` is normally granted to whoever is
logged in at the console. With no login session there is no such grant. Adding the
user to the `audio` group gives permanent access:

```bash
sudo usermod -aG audio $USER
```

**Encrypted home directories.** If the home directory is encrypted (ecryptfs, which
is what the Ubuntu installer's "encrypt my home folder" option uses), nothing under
`~` is readable until that user logs in and the directory is unlocked. That defeats
lingering entirely, because systemd cannot read a unit it cannot see.

This is why the config and unit above go in `/etc` rather than `~/.config`. There
is one more catch: `systemctl --user enable` writes its symlink into the home
directory anyway, which silently puts you back where you started. Move it:

```bash
# check where enable actually put it
ls -l ~/.config/systemd/user/default.target.wants/

# move it somewhere readable at boot
rm ~/.config/systemd/user/default.target.wants/pipewire-audio-hub.service
sudo mkdir -p /etc/systemd/user/default.target.wants
sudo ln -sf /etc/systemd/user/pipewire-audio-hub.service \
            /etc/systemd/user/default.target.wants/
```

Skip this if the home directory is not encrypted. The normal enable is fine.

Verify by rebooting without logging in, then checking from another machine over SSH
that the ports are bound.

## 7. Multiple destinations, optional

To expose more than one output, for example headphones and desk speakers, run a
second set of receivers on different ports and pin them to a different sink.

```
# headphones
local.source.port = 10001    target.object = "alsa_output.usb-...-00.analog-stereo"
# speakers
local.source.port = 10011    target.object = "bluez_output.XX_XX_XX_XX_XX_XX.1"
```

Each destination needs its own Roc port pair, and one VBAN port per Windows sender.
The example config includes both sets, commented.

Senders then choose a destination by aiming at a port. On macOS that means creating
two roc-vad devices, which show up as two separate output devices.

A Bluetooth sink works fine as a destination. Be aware that a receiver with
`node.always-process = true` will keep feeding the Bluetooth link continuously,
which usually prevents the speaker from powering itself off. If that bothers you,
set it to `false` on the Bluetooth receivers only, at the cost of them taking a
moment to wake.

## Next

- [Linux sender](sender-linux.md)
- [Windows sender](sender-windows.md)
- [macOS sender](sender-macos.md)
- [Troubleshooting](troubleshooting.md)
