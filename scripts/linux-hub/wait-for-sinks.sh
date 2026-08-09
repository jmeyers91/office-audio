#!/bin/sh
#
# Wait until every sink the hub pins with target.object actually exists, then
# let the receivers start.
#
# WHY THIS EXISTS
#
# pipewire-audio-hub.service is ordered After= pipewire and wireplumber, but
# neither of those being active means the target DEVICE nodes exist yet.
#
# If a receiver starts while its pinned sink is missing, the session manager
# cannot resolve target.object. It does not fail, and it does not retry: it
# falls back to the DEFAULT sink and stays there. The receivers are healthy,
# the ports are bound, the service is "active", and the audio comes out of the
# wrong hardware until somebody restarts the service by hand. Nothing is logged
# at the shipped log level, which is the whole problem.
#
# WHY A SINGLE-SINK CHECK IS NOT ENOUGH
#
# With one destination the fallback is invisible: if the only pinned sink IS
# the default sink, a receiver that fell back looks identical to one that was
# pinned correctly. It only becomes visible with a second destination, and by
# then it affects every sender at once. So this waits for ALL of them.
#
# WHAT THIS DOES NOT CATCH
#
# It tests that a sink is PRESENT, which is weaker than "linkable". A sink is
# listed while suspended, while its profile is still settling, and when all its
# ports report "not available" (see force-output-port.service.example). In
# those cases this reports success and a fallback can still happen. Presence is
# the cheap check that covers the common race, not a guarantee.
#
# INSTALL
#
#     sudo install -m 0755 wait-for-sinks.sh /usr/local/bin/audio-hub-wait-for-sinks
#     sudo mkdir -p /etc/systemd/user/pipewire-audio-hub.service.d
#     sudo install -m 0644 wait-for-sinks.conf.example \
#          /etc/systemd/user/pipewire-audio-hub.service.d/wait-for-sinks.conf
#     systemctl --user daemon-reload
#
# Usage: audio-hub-wait-for-sinks [config-path] [timeout-seconds]
#
# The default timeout is 30s. Raising it past about 80 requires also setting
# TimeoutStartSec= on the unit, or systemd kills the start as a timeout.

set -u

CONF=${1:-/etc/pipewire/audio-hub.conf}
TIMEOUT=${2:-30}

if [ ! -r "$CONF" ]; then
	echo "cannot read $CONF, not waiting for anything" >&2
	exit 0
fi

# Without pactl there is no way to answer the question. Say so rather than
# waiting out the timeout and then blaming the hardware.
if ! command -v pactl >/dev/null 2>&1; then
	echo "pactl not found, not waiting for anything" >&2
	exit 0
fi

# Strip comments first: a destination that has been commented out rather than
# deleted must not be waited on.
#
# Two kinds of target are skipped deliberately:
#
#   REPLACE_WITH_*   the shipped placeholders. audio-hub.conf.example says
#                    leaving an unused destination block in place is supported,
#                    so this must not turn that into a timeout every boot.
#
#   bluez_output.*   a Bluetooth speaker's sink does not exist until the
#                    speaker is powered on and connected, which at boot is
#                    normally not the case. Waiting for one would stall every
#                    boot by the full timeout and then cry wolf.
targets=$(
	sed -e '/^[[:space:]]*#/d' "$CONF" |
		sed -n 's/.*target\.object[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' |
		grep -v '^REPLACE_WITH_' |
		grep -v '^bluez_output\.' |
		sort -u
)

if [ -z "$targets" ]; then
	echo "no target.object pins to wait for in $CONF"
	exit 0
fi

# Node names have no business containing glob characters, but an unquoted word
# split below would expand them against the working directory if they did.
set -f

i=0
missing=$targets
while :; do
	missing=
	present=$(pactl list short sinks 2>/dev/null | cut -f2)
	for t in $targets; do
		printf '%s\n' "$present" | grep -qxF "$t" || missing="$missing $t"
	done

	[ -z "$missing" ] && break
	[ "$i" -ge "$TIMEOUT" ] && break

	i=$((i + 1))
	sleep 1
done

if [ -z "$missing" ]; then
	echo "all pinned target sinks present after ${i}s"
	exit 0
fi

# Deliberately exits 0. Failing here would fight Restart=always until systemd
# hit its start limit and gave up, leaving the machine with no audio at all.
echo "STARTING ANYWAY after ${TIMEOUT}s - pinned sink(s) never appeared:$missing" >&2
echo "  Receivers pinned to them will fall back to the DEFAULT sink, which means" >&2
echo "  that destination will play out of the wrong hardware. Fix the device, then" >&2
echo "  'systemctl --user restart pipewire-audio-hub' to re-link." >&2
exit 0
