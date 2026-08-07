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
   macOS sender  ──┐  Roc / RTP
   Linux sender  ──┤                      ┌─────────────────┐
                   ├─────────────────────▶│   Linux hub     │──▶ headphones,
   Windows sender──┤  VBAN / UDP          │   (PipeWire)    │    speakers, or
   Windows sender──┘                      └─────────────────┘    USB interface
```

The hub runs PipeWire with several network receiver modules loaded at once. Each
receiver shows up as an ordinary audio stream, so everything mixes automatically
and you get per source volume control.

There is no single protocol that covers every sender, so this setup uses two.

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

| Sender OS | Protocol | What you install | Has to keep running |
|---|---|---|---|
| Linux | Roc | nothing, PipeWire has the module | no |
| macOS | Roc | roc-vad | no |
| Windows | VBAN | Voicemeeter | yes |

The hub speaks both at the same time, so you can mix and match freely. If you have
no Macs, ignore the Roc half. If you have no Windows machines, ignore the VBAN half.

## Setup

Start with the hub, then add whichever senders you need. Each guide stands alone.

1. **[Linux hub](docs/hub-linux.md)** (required)
2. **[Windows sender](docs/sender-windows.md)**
3. **[macOS sender](docs/sender-macos.md)**
4. **[Linux sender](docs/sender-linux.md)**
5. **[Troubleshooting](docs/troubleshooting.md)** if something is silent

The Linux sender is the least work of the three. PipeWire already ships the module
it needs, so there is nothing to install and nothing that has to keep running.

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

VBAN needs one port per sender per destination. This is because the PipeWire VBAN
receiver in current stable releases cannot split multiple senders apart by stream
name, so each sender needs its own port to avoid the streams being mixed into
garbage. Roc has no such limitation and mixes senders on one port automatically.

## Network notes

Use wired ethernet for the hub. It is the aggregation point for every stream, so
it is the worst place to introduce jitter.

Wi-Fi senders can work, particularly with Roc, whose forward error correction is
designed for lossy links. Avoid multicast over Wi-Fi entirely. Access points send
multicast at the lowest basic rate with no link layer acknowledgement or retry, so
loss rates are high. Everything in this repo uses unicast.

Give the hub a static address or a DHCP reservation. Every sender hardcodes it, and
a changed lease means silently editing every machine.

## What this was tested on

- **Hub**: a small x86_64 business desktop from around 2016, Linux Mint 22.3
  (Ubuntu 24.04 base), PipeWire 1.0.5, wired gigabit ethernet.
- **Outputs**: onboard analog output and a Bluetooth speaker. A USB audio
  interface is the intended target and works the same way, since the hub just
  routes to whatever PipeWire sink you point it at.
- **Linux sender**: a laptop running the same Linux Mint 22.3 and PipeWire 1.0.5
  as the hub, over Wi-Fi.
- **macOS sender**: Apple Silicon, macOS 26, roc-vad 0.0.4.
- **Windows sender**: Windows 10 22H2, Voicemeeter Banana 2.0.6.8.

The PipeWire version matters more than the distribution. Several module options
were renamed or added after 1.0.5, and the guides call out where a newer PipeWire
behaves differently.

## Repository layout

```
docs/                     setup guides, one per role
scripts/linux-hub/        PipeWire client config and systemd unit
scripts/linux-sender/     PipeWire sender config
scripts/macos-sender/     roc-vad device setup
scripts/windows-sender/   Voicemeeter VBAN config and logon task
```

## License

MIT, see [LICENSE](LICENSE).
