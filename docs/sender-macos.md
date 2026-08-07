# macOS sender setup

macOS reaches the hub using Roc, which is the better of the two paths in this
project. It handles clock drift between machines properly, tolerates packet loss,
and carries volume control.

The result is a normal output device in System Settings. No application has to be
running for it to work.

## What you are installing

**roc-vad** is a virtual audio device for macOS built on Roc Toolkit. It installs a
CoreAudio plugin, so the devices it creates behave like any other sound card as far
as macOS and your applications are concerned.

It is a userspace AudioServerPlugIn, not a kernel extension, so System Integrity
Protection is not involved and you do not need to reduce security settings.

Project page: [github.com/roc-streaming/roc-vad](https://github.com/roc-streaming/roc-vad)

## 1. Install

```bash
sudo /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/roc-streaming/roc-vad/HEAD/install.sh)"
```

The installer is short and worth reading first if you are cautious about piping to
`sudo bash`. All it does is download a release tarball and extract two paths:

```
/Library/Audio/Plug-Ins/HAL/roc_vad.driver
/usr/local/bin/roc-vad
```

### The installer's error message is usually a lie

On current macOS the installer commonly finishes with something like:

```
x /usr/: Can't create '/usr': No such file or directory
x /Library/: Can't create '/Library': No such file or directory
...
tar: Error exit delayed from previous errors.
error: Failed to unpack /tmp/roc-vad.tar.bz2 into /
```

This looks fatal and generally is not. The only failures are `tar` trying to create
`/usr` and `/Library`, which already exist and are protected by SIP. Every actual
payload line extracts fine, but `tar` still exits non-zero, so the script reports
failure.

Check for yourself rather than trusting either message:

```bash
ls -l /Library/Audio/Plug-Ins/HAL/roc_vad.driver /usr/local/bin/roc-vad
```

If both exist, the install worked.

## 2. Load the driver

The installer asks for a reboot. Restarting CoreAudio is normally enough:

```bash
sudo killall coreaudiod
```

Audio on the machine cuts out for a second. Then:

```bash
roc-vad info
```

`driver is loaded` means you are done. If it is not loaded, do the full reboot.

## 3. Create the device

```bash
roc-vad device add sender --name "Hub Speakers" --fec-encoding disable
```

**`--fec-encoding disable` matters.** roc-vad defaults to `rs8m` forward error
correction, and many Linux distributions ship libroc built without OpenFEC. If the
hub cannot do FEC and the sender insists on it, `device connect` refuses the plain
address in the next step. Set this to match your hub. If your hub does have FEC,
leave the flag off and use the `rtp+rs8m://` form below instead.

Note the device index that command prints. It is not always 1, particularly if you
have created and deleted devices while experimenting.

## 4. Connect it to the hub

For a hub with FEC disabled, which is the common case:

```bash
roc-vad device connect <INDEX> \
  --source  rtp://HUB_IP:10001 \
  --control rtcp://HUB_IP:10003
```

For a hub with FEC enabled:

```bash
roc-vad device connect <INDEX> \
  --source  rtp+rs8m://HUB_IP:10001 \
  --repair  rs8m://HUB_IP:10002 \
  --control rtcp://HUB_IP:10003
```

The project's own README shows the FEC form, so it is easy to copy the wrong one.
The scheme in `--source` has to match the device's `fec-encoding` and the hub's
`fec.code`. Mismatches give you either a refusal here or silence later.

The `--control` endpoint is not optional in practice. It carries RTCP, which is
what does latency tuning and makes the macOS volume slider affect playback.

## 5. Use it

"Hub Speakers" now appears in System Settings under Sound, and in the menu bar
volume control. Select it and audio goes to the hub. Volume and mute work as
normal.

## Multiple destinations

If the hub exposes more than one output, create one device per destination. Each
appears separately in System Settings, so switching between them is an ordinary
output device change.

```bash
roc-vad device add sender --name "Hub Headphones" --fec-encoding disable
roc-vad device connect <INDEX> --source rtp://HUB_IP:10001 --control rtcp://HUB_IP:10003

roc-vad device add sender --name "Hub Speakers" --fec-encoding disable
roc-vad device connect <INDEX> --source rtp://HUB_IP:10011 --control rtcp://HUB_IP:10013
```

## Managing devices

```bash
roc-vad device list
roc-vad device show <INDEX>
roc-vad device del <INDEX>
```

Devices are held by the driver rather than by a running application, so they are
expected to survive reboots. Confirm with `roc-vad device list` after your first
restart rather than assuming it.

## Uninstall

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/roc_vad.driver
sudo rm -f /usr/local/bin/roc-vad
sudo killall coreaudiod
```

## Version note

roc-vad 0.0.4 was tested on macOS 26 on Apple Silicon and worked, although the
project's CI at the time only covered up to macOS 15. The binaries are universal,
so both Apple Silicon and Intel are covered. If a future macOS breaks the plugin,
the two paths above are the whole install and removing them leaves nothing behind.

## Next

- [Troubleshooting](troubleshooting.md)
- [Linux hub setup](hub-linux.md)
