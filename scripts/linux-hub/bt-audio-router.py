#!/usr/bin/env python3
"""Route incoming Bluetooth audio to a sink chosen by WHICH ADAPTER it arrived on.

Only needed if you have TWO OR MORE Bluetooth adapters and want each to feed a
different output. With one adapter, a WirePlumber rule is simpler; see
docs/sender-phone-bluetooth.md.

Why this cannot be a WirePlumber rule:

A connected phone appears as a Stream/Output/Audio node named
bluez_input.<PHONE_MAC>.<n>, created only while audio is actually streaming.
Nothing on that node identifies the adapter: node.name derives from the PHONE,
and api.bluez5.transport is empty even mid-stream. The only link to the adapter
is device.id, pointing at a Device object whose api.bluez5.path looks like
/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF.

Matching that property in a rule does NOT work: it applies to the device, and
target.object has to take effect on the node. It does not propagate across that
boundary, and both adapters end up on the same sink.

Two things worth knowing if you modify this:

  - hciN numbering is NOT stable. A USB dongle can move between hci1 and hci2
    across replugs, so decisions are keyed on the adapter's MAC.
  - /sys/class/bluetooth/<hci>/address does NOT exist. The MAC comes from
    hciconfig.

Install:
    sudo cp bt-audio-router.py /usr/local/bin/
    sudo cp bt-audio-router.service /etc/systemd/user/
    sudo ln -sf /etc/systemd/user/bt-audio-router.service \
                /etc/systemd/user/default.target.wants/
    systemctl --user daemon-reload && systemctl --user start bt-audio-router
"""

import json
import re
import subprocess
import sys
import time

# ============================== SETTINGS ===================================

# Adapter MAC -> sink its audio should play through.
# Adapter addresses:  hciconfig
# Sink names:         pactl list short sinks
ADAPTER_SINKS = {
    "AA:BB:CC:DD:EE:F1": "REPLACE_WITH_FIRST_SINK_NAME",
    "AA:BB:CC:DD:EE:F2": "REPLACE_WITH_SECOND_SINK_NAME",
}

# Used when the adapter is unknown or cannot be resolved.
DEFAULT_SINK = "REPLACE_WITH_FIRST_SINK_NAME"

POLL_SECONDS = 2

# ===========================================================================


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True,
                              text=True, timeout=15).stdout
    except Exception:
        return ""


def adapter_macs():
    """{hciN: MAC} parsed from hciconfig. sysfs has no address file."""
    macs, cur = {}, None
    for line in sh("hciconfig").splitlines():
        if line and not line[0].isspace():
            cur = line.split(":")[0].strip()
        elif "BD Address:" in line and cur:
            macs[cur] = line.split("BD Address:")[1].split()[0].upper()
    return macs


def bluez_streams(macs):
    """[(node_name, adapter_mac_or_None)] for live bluez input streams."""
    try:
        dump = json.loads(sh("pw-dump") or "[]")
    except json.JSONDecodeError:
        return []
    objects = {o.get("id"): o for o in dump}
    found = []
    for o in dump:
        props = (o.get("info") or {}).get("props") or {}
        name = str(props.get("node.name", ""))
        if not name.startswith("bluez_input"):
            continue
        dev = objects.get(props.get("device.id")) or {}
        path = str(((dev.get("info") or {}).get("props") or {}).get("api.bluez5.path", ""))
        m = re.search(r"/org/bluez/(hci\d+)/", path)
        found.append((name, macs.get(m.group(1)) if m else None))
    return found


def sink_inputs():
    """{node_name: (pactl_index, current_sink_name)}"""
    sinks = {}
    for line in sh("pactl list short sinks").splitlines():
        f = line.split("\t")
        if len(f) >= 2:
            sinks[f[0]] = f[1]
    result, idx, sink, name = {}, None, None, None
    for line in sh("pactl list sink-inputs").splitlines():
        s = line.strip()
        if s.startswith("Sink Input #"):
            if idx and name:
                result[name] = (idx, sinks.get(sink, ""))
            idx, sink, name = s.split("#")[1], None, None
        elif s.startswith("Sink:"):
            sink = s.split(":", 1)[1].strip()
        elif s.startswith("node.name ="):
            name = s.split("=", 1)[1].strip().strip('"')
    if idx and name:
        result[name] = (idx, sinks.get(sink, ""))
    return result


def main():
    print("bt-audio-router: watching for Bluetooth streams", flush=True)
    last = {}
    while True:
        try:
            macs = adapter_macs()
            inputs = sink_inputs()
            live = set()
            for name, mac in bluez_streams(macs):
                live.add(name)
                if name not in inputs:
                    continue
                index, current = inputs[name]
                want = ADAPTER_SINKS.get(mac, DEFAULT_SINK)
                if current != want:
                    sh("pactl move-sink-input %s %s" % (index, want))
                    print("moved %s (adapter %s) -> %s" % (name, mac, want), flush=True)
                elif last.get(name) != want:
                    print("%s (adapter %s) on %s" % (name, mac, want), flush=True)
                last[name] = want
            for gone in [n for n in last if n not in live]:
                del last[gone]
        except Exception as e:  # never die on a transient failure
            print("error: %s" % e, file=sys.stderr, flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
