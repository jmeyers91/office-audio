# office-audio

Turn one Linux machine into a network audio receiver so that every other computer
on your desk can play through the same speakers or headphones, without replugging
anything.

You plug your good headphones (or a USB audio interface, or a Bluetooth speaker)
into a single always-on Linux box. Every other machine in the room gets a normal
looking output device in its sound settings, something like "Hub Speakers". Pick
it, and that machine's audio comes out of the shared hardware. Several machines
can play at once and they mix together, each with its own volume slider on the hub.

## Why you might want this

The usual alternatives are a USB switch (one button, but only one computer at a
time and the device disconnects and reconnects on every switch) or an analog mixer
(works well, but needs a cable run from every machine). This approach needs no new
cables and lets more than one machine be audible at the same time, at the cost of
some latency and a bit of setup.

## Why you might not

Network audio adds somewhere around 50 to 100 ms of delay. That is fine for music,
podcasts, and video calls. It is usually fine for video, though lip sync can drift
depending on how well the player compensates. It is noticeable in games and it is
unusable for monitoring an instrument you are playing.

If you have one latency critical machine, the simplest answer is to leave its
audio hardware plugged in directly and only stream the machines where a bit of
delay does not matter.

## How it works

```
   macOS sender  ──┐  Roc, one shared port
   Linux sender  ──┤                      ┌─────────────────┐
                   ├─────────────────────▶│   Linux hub     │──▶ headphones,
   Windows PC 1  ──┤  VBAN, port 6980     │   (PipeWire)    │    speakers, or
   Windows PC 2  ──┘  VBAN, port 6981     └─────────────────┘    USB interface
                                                   ▲
   phone  ─────────────────────────────────────────┘  Bluetooth A2DP
```

Note the two Windows ports. Roc senders share one port and are mixed
automatically, but each VBAN sender needs its own or they interleave into noise.

The hub runs PipeWire with several network receiver modules loaded at once. Each
receiver shows up as an ordinary audio stream, so everything mixes automatically
and you get per source volume control. A phone connecting over Bluetooth arrives
the same way and mixes alongside the network senders.

There is no single protocol that covers every sender, so this setup uses three.

### The tools involved

Some of these are niche, so here is what each one actually is.

**PipeWire** is the audio server used by most current Linux desktops, replacing
PulseAudio and JACK. The important part here is that it ships network send and
receive modules in the box, so the hub needs no third party software.

**Roc Toolkit** is a library for real time audio streaming over networks that lose
packets, such as Wi-Fi. It handles clock drift between machines and can recover
lost packets using forward error correction. PipeWire includes Roc sender and
receiver modules. Roc supports Linux, macOS, and Android, but **not Windows**.

**roc-vad** is a macOS virtual audio device built on Roc. It installs a CoreAudio
plugin so that a Roc stream appears in System Settings as a normal output device.

**VBAN** is VB-Audio's UDP protocol for carrying uncompressed audio over a LAN.
It is simple and has no loss recovery, which is fine on wired ethernet. PipeWire
includes VBAN send and receive modules.

**Voicemeeter** is a virtual audio mixer for Windows. It installs virtual sound
cards that applications can play into, and it can route those into a VBAN stream.
Since Roc has no Windows support, this is how Windows machines reach the hub.

### Which protocol goes with which sender

| Sender | Protocol | What you install | Has to keep running |
|---|---|---|---|
| Linux | Roc | nothing, PipeWire has the module | no |
| macOS | Roc | roc-vad | no |
| Windows | VBAN | Voicemeeter | yes |
| Phone | Bluetooth | nothing at all | no |

A phone is the odd one out: it connects to the hub as if it were a Bluetooth
speaker, so it needs no app. That also means it works with apps that block audio
capture, which rules out the Android Roc app for most real use.

The hub speaks both at the same time, so you can mix and match freely.

Note that **Roc covers both macOS and Linux senders**. If you have no Windows
machines you can ignore the VBAN half, and if you have no Macs *and* no Linux
senders you can ignore the Roc half. Having no Macs on its own is not a reason to
skip Roc.

## Before you start

- All machines on the same LAN, able to reach each other directly. No NAT and no
  routing between them. This is not designed to cross networks.
- **A fixed address for the hub**, set up before you begin. Every sender hardcodes
  it. A DHCP reservation is fine.
- Ability to open UDP ports on the hub if it runs a firewall.
- The hub should be wired. Senders can be wireless.

Roughly 1.4 Mbit/s per active stream at 16-bit 44.1 kHz stereo, so four senders is
about 6 Mbit/s. Irrelevant on wired gigabit, worth knowing on congested Wi-Fi. CPU
cost on the hub is small; a 2016 desktop handles six receivers without noticing.

## Setup

Start with the hub, then add whichever senders you need. Each guide stands alone.

1. **[Linux hub](docs/hub-linux.md)** (required, start here)
2. **[Linux sender](docs/sender-linux.md)** if you have one, do it next: it is the
   quickest of the three and proves the hub works end to end before you take on
   anything more fiddly
3. **[macOS sender](docs/sender-macos.md)**
4. **[Windows sender](docs/sender-windows.md)**, the most involved of the three
5. **[Phone over Bluetooth](docs/sender-phone-bluetooth.md)**, needs no app at all
6. **[Troubleshooting](docs/troubleshooting.md)** if something is silent

### When you are done

You should be able to select the hub device on every machine, play audio on several
at once, hear them mixed, and see each one as a separate stream with its own volume
slider in `pavucontrol` on the hub. That last part is the payoff over a USB switch,
and it is worth confirming deliberately rather than assuming.

## Multiple destinations

You are not limited to one output. The hub can expose several independent
destinations, for example headphones and desk speakers, and each sender picks
between them.

The trick is that the destination is chosen entirely by **port number**. You run a
separate set of receivers per destination and pin each set to a specific audio
device on the hub. A sender aiming at one port lands on the headphones, another
port lands on the speakers. On macOS you create two roc-vad devices and both appear
in System Settings, so switching is a normal output device change.

The hub guide covers this. If you only want one destination, skip that section.

## Port scheme

Nothing here is magic, but the guides all assume the same layout so the examples
line up. Change it if you like, as long as sender and receiver agree.

| Destination | Roc source | Roc control | VBAN, first Windows PC | VBAN, second Windows PC |
|---|---|---|---|---|
| Headphones | 10001 | 10003 | 6980 | 6981 |
| Speakers | 10011 | 10013 | 6990 | 6991 |

Roc needs two ports per destination: one for audio and one for RTCP control, which
is what carries latency tuning and lets sender side volume work. A third port is
used for forward error correction repair packets when FEC is enabled, which by
default on many distributions it is not. See the hub guide.

VBAN needs one port per sender per destination. **Two Windows machines must not
share a port**, or their streams interleave into noise. This is because the
PipeWire VBAN receiver up to and including 1.2 cannot split senders apart by stream
name. Newer PipeWire adds `stream.rules` matching on `sess.name`, which would let
one receiver handle several senders, but the per-port approach here works on every
version. Roc has no such limitation and mixes senders on one port automatically.

## Network notes

Use wired ethernet for the hub. It is the aggregation point for every stream, so
it is the worst place to introduce jitter.

Wi-Fi senders can work, particularly with Roc, whose forward error correction is
designed for lossy links. Avoid multicast over Wi-Fi entirely. Access points send
multicast at the lowest basic rate with no link layer acknowledgement or retry, so
loss rates are high. Everything in this repo uses unicast.

Give the hub a static address or a DHCP reservation. Every sender hardcodes it, and
a changed lease means silently editing every machine.

**There is no authentication or encryption on either protocol.** Anything that can
reach the hub's ports can play audio through your speakers. Scope your firewall
rules to your own subnet, and do not forward these ports through a router. See the
security section in the [hub guide](docs/hub-linux.md#security).

## Living with it

Once it works, per source volume is the part you will actually use day to day. Run
`pavucontrol` on the hub and every sender appears on the Playback tab as its own
stream with its own slider, so you can duck the noisy machine without touching the
others. Senders keep their own local volume control as well.

If the hub reboots or drops off the network, senders do not error. Roc senders
reconnect on their own once it returns, since the endpoint is a fixed address rather
than a session. VBAN senders simply keep transmitting into the void and resume when
the hub is back. In both cases the sending machine stays silent rather than falling
back to local speakers, which is worth knowing before you spend ten minutes
wondering why a video has no sound.

## What this was tested on

- **Hub**: a small x86_64 business desktop from around 2016, Linux Mint 22.3
  (Ubuntu 24.04 base), PipeWire 1.0.5, wired gigabit ethernet.
- **Outputs**: onboard analog output and a Bluetooth speaker. A USB audio
  interface is the intended target and works the same way, since the hub just
  routes to whatever PipeWire sink you point it at.
- **Linux sender**: a laptop running the same Linux Mint 22.3 and PipeWire 1.0.5
  as the hub, over Wi-Fi.
- **macOS sender**: Apple Silicon, macOS 26, roc-vad 0.0.4.
- **Phone**: Android 15 over Bluetooth A2DP, using two USB/M.2 adapters so the
  phone sees two separate devices.
- **Windows sender**: Windows 10 22H2, Voicemeeter Banana 2.0.6.8. Windows 11 is
  untested. Nothing here is version specific and it should work unchanged, but the
  classic Sound control panel is buried deeper, so the guide uses `mmsys.cpl`.

The PipeWire version matters more than the distribution. Several module options
were renamed or added after 1.0.5, and the guides call out where a newer PipeWire
behaves differently.

## Repository layout

```
docs/                     setup guides, one per role
scripts/linux-hub/        PipeWire client config, systemd units, Bluetooth
scripts/linux-sender/     PipeWire sender config
scripts/macos-sender/     roc-vad device setup
scripts/windows-sender/   Voicemeeter VBAN config and logon task
```

## License

MIT, see [LICENSE](LICENSE).
