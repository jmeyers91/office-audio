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
  so=$(ls /usr/lib/*/pipewire-0.3/libpipewire-module-$m.so 2>/dev/null | head -1)
  if [ -z "$so" ]; then
    echo "MISSING   $m  (module not built into this PipeWire)"
  elif ldd "$so" 2>/dev/null | grep -q 'not found'; then
    echo "BROKEN    $m  (missing shared library):"
    ldd "$so" | grep 'not found' | sed 's/^/            /'
  else
    echo "ok        $m"
  fi
done
```

Check the linkage, not just the file. The file existing does not mean the module
loads. Ubuntu has shipped `libpipewire-module-roc-source.so` without `libroc`
present, in which case the module fails and takes the whole PipeWire user service
down with it
([LP#2096683](https://bugs.launchpad.net/ubuntu/+source/pipewire/+bug/2096683)).
That is exactly the failure this guide warns about hardest, so it is worth catching
in the first minute rather than the third hour.

What to do with each result:

- **ok**: nothing to install.
- **BROKEN**: install the library it names, usually something like
  `sudo apt install libroc0.3`. Package names vary by distribution.
- **MISSING**: your PipeWire was built without that module. Installing `libroc`
  will not help, because the module is compiled as part of PipeWire, not shipped
  by the Roc packages. You need a newer distribution release, a PPA with a fuller
  PipeWire build, or a source build. There is no package that fixes this.

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

If that prints nothing, your build almost certainly has no FEC. Use
`fec.code = disable` in the config below, and have every sender use a plain
`rtp://` source address with no repair endpoint. The two must agree. A sender using
`rtp+rs8m://` against a receiver with FEC disabled will produce silence and no
useful error.

This check can give a false negative if OpenFEC was linked statically, which `ldd`
cannot see. If you would rather be certain, set `fec.code = rs8m` and start the
service. It either loads, or it logs `no codec available for fec scheme 'rs8m'` and
refuses, which is a definitive answer. With `nofail` set that costs you nothing.

You can also confirm after the fact: with FEC disabled the repair port never
appears in `ss -uln`, which is expected and not a fault.

Losing FEC only matters on lossy links. On wired ethernet it makes no practical
difference. If you need it and your distribution does not ship it, you would have
to build roc-toolkit from source with `--build-3rdparty=openfec`.

## 3. Write the receiver config

Make a local copy inside the repo and edit **that**. It is already gitignored, so
your addresses and device names stay out of version control. You will install it in
step 4.

```bash
cp scripts/linux-hub/audio-hub.conf.example scripts/linux-hub/audio-hub.conf
$EDITOR scripts/linux-hub/audio-hub.conf
```

The important decisions are which ports to listen on and which sink each receiver
feeds.

**If you only want one destination, delete the DESTINATION 2 block now.** Left in
with its placeholder sink name, those modules still load, still bind their ports,
and never link to anything, which makes the verification in step 5 much harder to
read.

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
set it on both ends.

The examples use **44100** because that is roc-vad's default, so a mixed setup with
Macs in it stays consistent without extra configuration.

**If you have no Macs, use 48000 instead.** Windows and Linux both run at 48000
natively, so 44100 forces a pointless resample on every sender. Set `audio.rate =
48000` on each `vban-recv` block and `SR` to 48000 in Voicemeeter.

Roc negotiates properly and does not have this problem, so this only affects VBAN.

### A note on option names

On PipeWire 1.0.5 the Roc resampler option is `resampler.profile`. Newer versions
renamed it to `roc.resampler.profile` and treat the old name as deprecated rather
than invalid, so the shipped config keeps working either way. It is worth knowing
the difference only so that the online documentation matching your version does not
confuse you.

In general, check option names against your installed version:

```bash
man 7 libpipewire-module-roc-source
man 7 libpipewire-module-vban-recv
```

The manpage on the machine is authoritative. The website may describe a version you
do not have.

## 4. Install the service

Install the copy you just edited, not the example.

```bash
sudo cp scripts/linux-hub/audio-hub.conf /etc/pipewire/audio-hub.conf
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
# receivers exist and are linked to a sink.
# grep on your own node.name prefix rather than on port names, which vary.
pw-link -l | grep -A1 '^hub-'

# the ports are actually bound
ss -uln | grep -E ':(6980|6981|10001|10003) '

# no errors
journalctl --user -u pipewire-audio-hub | grep -iE 'err|fail'
```

That last command only tells you anything if logging is on. The example config
ships `log.level = 2`; if you set it to 0 you will get an empty journal, which
looks identical to "no errors".

If your firewall is active, open the UDP ports you configured. **Open only the
ports you actually use**, and scope them to your LAN rather than the world. Neither
protocol has any authentication, so anything that can reach these ports can play
audio through your speakers.

```bash
LAN=192.168.1.0/24        # your subnet

# destination 1
sudo ufw allow from $LAN to any port 10001:10003 proto udp   # Roc
sudo ufw allow from $LAN to any port 6980:6981   proto udp   # VBAN, one per Windows PC

# destination 2, only if you configured one
sudo ufw allow from $LAN to any port 10011:10013 proto udp
sudo ufw allow from $LAN to any port 6990:6991   proto udp
```

Note the second Roc range. It is easy to open 10001-10003 only, then wonder why the
second destination works over VBAN but is silent over Roc.

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

Verify by rebooting without logging in, then checking from another machine over SSH.
Check the **links**, not just the ports:

```bash
ss -uln | grep -E ':(6980|10001) '     # necessary, not sufficient
pw-link -l | grep -A1 '^hub-'          # this is the real test
```

The ports bind even when the receiver never linked to a sink, so a port check alone
will happily report success on a hub that produces no sound.

### If it comes up dead, or misrouted, after a cold boot

`After=wireplumber.service` orders startup but does not guarantee your sink
**exists** by the time the receivers start. Any device that enumerates late can lose
that race, and it is not only USB: an onboard codec can appear after a USB
interface that was already attached at power-on. There are two possible outcomes,
and the second is much harder to spot than the first.

**Dead.** The receiver fails with "no target node available", which is the failure
the client context design exists to avoid. `Restart=always` does not help, because
with `nofail` the process stays alive with a dead stream.

**Misrouted.** The receiver links to the **default sink** instead and never moves
back. This happens when *some* sink exists but the pinned one does not, and it is
silent: the service is `active`, the ports are bound, the receivers are healthy,
and the audio comes out of the wrong hardware. Nothing is logged at the shipped
`log.level`.

With one destination you will never notice the second case, because the only
pinned sink is usually the default sink too, so falling back changes nothing. It
surfaces the day you add a second destination, and then it affects every sender at
once. See
[troubleshooting.md](troubleshooting.md#one-destination-plays-out-of-another-destinations-hardware).

Either way the immediate fix is:

```bash
systemctl --user restart pipewire-audio-hub
```

To make it stick, have the unit wait for the sinks before starting. Install
[`wait-for-sinks.sh`](../scripts/linux-hub/wait-for-sinks.sh) and its drop-in:

```bash
sudo install -m 0755 scripts/linux-hub/wait-for-sinks.sh \
     /usr/local/bin/audio-hub-wait-for-sinks
sudo mkdir -p /etc/systemd/user/pipewire-audio-hub.service.d
sudo install -m 0644 scripts/linux-hub/wait-for-sinks.conf.example \
     /etc/systemd/user/pipewire-audio-hub.service.d/wait-for-sinks.conf
systemctl --user daemon-reload
```

It reads the sink names out of your `target.object` lines, so it does not need
editing and cannot drift when you add a destination. It waits for **all** of them,
then starts anyway after 30 seconds rather than blocking forever, logging loudly if
a sink never appeared. Raising that past about 80 seconds needs `TimeoutStartSec=`
on the unit too, or systemd kills the start instead.

Three limits worth knowing before you rely on it:

- It skips `bluez_output.*` targets and the shipped `REPLACE_WITH_*` placeholders.
  A Bluetooth speaker's sink does not exist until the speaker is connected, so
  waiting for one would stall every boot and then report a fault that is not real.
- It checks a sink is **present**, which is weaker than linkable. A sink is listed
  while suspended and while all its ports report "not available", and a fallback is
  still possible in those states. It covers the common race, not every case.
- If you also use `force-output-port.service.example`, the two run in sequence and
  their waits add up.

Verify by rebooting and checking the journal:

```bash
journalctl --user -u pipewire-audio-hub -b | grep 'pinned target sinks'
pw-link -l | grep -A1 '^hub-'
```

A boot that reports `present after 0s` tells you the sinks were ready anyway; it
does not exercise the guard. The case it exists for is the boot where that number
is non-zero, or where the warning appears.

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

## Security

Worth being explicit, because it is easy to miss.

**Neither protocol has any authentication or encryption.** Roc and VBAN are plain
UDP. Anything that can reach these ports can play audio out of your speakers at
whatever volume it likes, and anyone who can capture traffic between the machines
can reconstruct the audio.

On a home LAN that is a footnote. On a shared or work network it is a real
conversation, particularly if the hub is somewhere audio could be embarrassing.

Two things worth doing:

- **Scope the firewall rules to your subnet**, as in step 5, rather than opening
  the ports to everything.
- **Bind to one interface** instead of all of them. Every receiver accepts
  `local.ifname`, so on a machine with more than one network you can keep this off
  the others entirely:

  ```
  local.ifname = eno1
  ```

  The examples use `0.0.0.0` because it works everywhere without editing, not
  because it is the best choice.

Do not forward these ports through a router. There is no scenario in this design
where the hub should be reachable from outside your network.

## Uninstall

```bash
systemctl --user disable --now pipewire-audio-hub.service
sudo rm -f /etc/pipewire/audio-hub.conf
sudo rm -f /etc/systemd/user/pipewire-audio-hub.service
sudo rm -f /etc/systemd/user/default.target.wants/pipewire-audio-hub.service
rm -f ~/.config/systemd/user/default.target.wants/pipewire-audio-hub.service
systemctl --user daemon-reload
systemctl --user restart pipewire pipewire-pulse wireplumber
```

Optionally undo the boot setup, if you added it and want it gone:

```bash
sudo loginctl disable-linger $USER
sudo gpasswd -d $USER audio      # only if you did not already need this
```

And remove whichever firewall rules you added. Nothing here installs packages or
modifies PipeWire itself, so once these files are gone the machine is back to a
stock audio setup.

## Next

- [Linux sender](sender-linux.md)
- [Windows sender](sender-windows.md)
- [macOS sender](sender-macos.md)
- [Troubleshooting](troubleshooting.md)
