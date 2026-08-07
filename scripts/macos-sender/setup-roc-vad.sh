#!/usr/bin/env bash
#
# office-audio: create a roc-vad output device pointing at the Linux hub.
#
# Assumes roc-vad is already installed. See docs/sender-macos.md.
#
# Usage:
#   ./setup-roc-vad.sh "Hub Speakers" 192.0.2.10 10001 10003
#   ./setup-roc-vad.sh <device name> <hub ip> <source port> <control port>

set -euo pipefail

NAME="${1:-Hub Speakers}"
HUB_IP="${2:-}"
SOURCE_PORT="${3:-10001}"
CONTROL_PORT="${4:-10003}"

# Set to 1 only if your hub's libroc was built WITH OpenFEC. Check on the hub:
#   ldd /lib/*/libroc.so* | grep -i fec
# Most distribution packages are built without, so this defaults to off.
USE_FEC="${USE_FEC:-0}"
REPAIR_PORT="${REPAIR_PORT:-10002}"

ROC_VAD="${ROC_VAD:-/usr/local/bin/roc-vad}"

if [[ -z "$HUB_IP" ]]; then
    echo "error: hub IP is required" >&2
    echo "usage: $0 <device name> <hub ip> [source port] [control port]" >&2
    exit 1
fi

if [[ ! -x "$ROC_VAD" ]]; then
    echo "error: roc-vad not found at $ROC_VAD" >&2
    echo "install it first, see docs/sender-macos.md" >&2
    exit 1
fi

if ! "$ROC_VAD" info 2>/dev/null | grep -q "driver is loaded"; then
    echo "error: roc-vad driver is not loaded" >&2
    echo "try: sudo killall coreaudiod" >&2
    exit 1
fi

echo "Creating device \"$NAME\" ..."

if [[ "$USE_FEC" == "1" ]]; then
    "$ROC_VAD" device add sender --name "$NAME"
else
    # The hub cannot do FEC, so the device must not ask for it. Without this the
    # connect below is rejected, because a plain rtp:// source is not valid for a
    # device configured with rs8m.
    "$ROC_VAD" device add sender --name "$NAME" --fec-encoding disable
fi

# device add does not return the index in a machine readable way, so read it back.
INDEX="$("$ROC_VAD" device list | awk -v n="$NAME" '$0 ~ n {print $1}' | tail -1)"

if [[ -z "$INDEX" ]]; then
    echo "error: could not determine the new device index" >&2
    echo "run '$ROC_VAD device list' and connect it by hand" >&2
    exit 1
fi

echo "Connecting device $INDEX to $HUB_IP ..."

if [[ "$USE_FEC" == "1" ]]; then
    "$ROC_VAD" device connect "$INDEX" \
        --source  "rtp+rs8m://${HUB_IP}:${SOURCE_PORT}" \
        --repair  "rs8m://${HUB_IP}:${REPAIR_PORT}" \
        --control "rtcp://${HUB_IP}:${CONTROL_PORT}"
else
    "$ROC_VAD" device connect "$INDEX" \
        --source  "rtp://${HUB_IP}:${SOURCE_PORT}" \
        --control "rtcp://${HUB_IP}:${CONTROL_PORT}"
fi

echo
echo "Done. \"$NAME\" should now appear in System Settings under Sound."
echo "If you hear nothing, check from the hub that packets are arriving:"
echo "  sudo tcpdump -i any -n 'udp port ${SOURCE_PORT}' -c 20"
