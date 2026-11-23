#!/usr/bin/env bash
# End-to-end check of the installed package, run as a normal user after
# `pacman -U`. Upstream's own tests link the crate in-process and stub out the
# UI, so this covers what they cannot: the shipped binary against current Arch
# libraries, the shipped .service and .portal files, routing through the real
# xdg-desktop-portal frontend, and a GTK file dialog on a real compositor.
#
# Needs: dbus, glib2 (gdbus), weston, xdg-desktop-portal.
set -euo pipefail

BUS=org.freedesktop.impl.portal.desktop.gtk4
OBJ=/org/freedesktop/portal/desktop
PORTAL_FILE=/usr/share/xdg-desktop-portal/portals/gtk4.portal
BINARY=/usr/lib/xdg-desktop-portal-gtk4

step() { printf '\n== %s\n' "$*"; }
fail() {
	echo "::error::e2e: $*"
	exit 1
}

if [[ -z ${E2E_INNER:-} ]]; then
	XDG_RUNTIME_DIR=$(mktemp -d)
	XDG_CONFIG_HOME=$(mktemp -d)
	export XDG_RUNTIME_DIR XDG_CONFIG_HOME
	export XDG_CURRENT_DESKTOP=e2e WAYLAND_DISPLAY=wayland-e2e GDK_BACKEND=wayland
	export RUST_LOG=${RUST_LOG:-debug}
	mkdir -p "$XDG_CONFIG_HOME/xdg-desktop-portal"
	printf '[preferred]\ndefault=gtk4\n' >"$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf"

	step "start headless weston"
	weston --backend=headless --socket="$WAYLAND_DISPLAY" --idle-time=0 \
		>"$XDG_RUNTIME_DIR/weston.log" 2>&1 &
	weston_pid=$!
	trap 'kill $weston_pid 2>/dev/null || true' EXIT
	for _ in $(seq 50); do
		[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break
		sleep 0.1
	done
	[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] || {
		cat "$XDG_RUNTIME_DIR/weston.log"
		fail "weston did not create its socket"
	}
	echo "weston up on $WAYLAND_DISPLAY"

	E2E_INNER=1 dbus-run-session -- "$0"
	exit
fi

dbus() { gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
	--method "org.freedesktop.DBus.$1" "${@:2}"; }

step "D-Bus activation from the shipped .service file"
dbus StartServiceByName "$BUS" 0 >/dev/null || fail "could not activate $BUS"
pid=$(dbus GetConnectionUnixProcessID "$BUS" | sed -n 's/.*uint32 \([0-9]*\).*/\1/p')
exe=$(readlink "/proc/$pid/exe")
[[ $exe == "$BINARY" ]] || fail "$BUS is owned by $exe, expected $BINARY"
echo "$BUS owned by pid $pid ($exe)"

step "exported interfaces match $PORTAL_FILE"
want=$(sed -n 's/^Interfaces=//p' "$PORTAL_FILE" | tr ';' '\n' | sed '/^$/d' | sort)
have=$(gdbus introspect --session --dest "$BUS" --object-path "$OBJ" |
	sed -n 's/^ *interface \(org\.freedesktop\.impl\.portal\.[A-Za-z]*\) {.*/\1/p' | sort)
missing=$(comm -23 <(echo "$want") <(echo "$have"))
[[ -z $missing ]] || fail "listed in gtk4.portal but not exported: $missing"
echo "all $(wc -l <<<"$want") interfaces exported"

step "Settings through the xdg-desktop-portal frontend"
direct=$(gdbus call --session --dest "$BUS" --object-path "$OBJ" \
	--method org.freedesktop.impl.portal.Settings.ReadAll "['org.freedesktop.appearance']") ||
	fail "backend Settings.ReadAll failed"
front=$(gdbus call --session --dest org.freedesktop.portal.Desktop --object-path "$OBJ" \
	--method org.freedesktop.portal.Settings.ReadAll "['org.freedesktop.appearance']") ||
	fail "frontend Settings.ReadAll failed"
echo "backend:  $direct"
echo "frontend: $front"
[[ $front == *color-scheme* ]] || fail "frontend did not return color-scheme"
# Dict order differs between the two, so compare sorted key/value pairs.
pairs() { grep -o "'[a-z-]*': <[^>]*>" <<<"$1" | sort; }
[[ $(pairs "$front") == "$(pairs "$direct")" ]] ||
	fail "frontend and backend disagree, so the frontend is not routing to gtk4"

step "FileChooser dialog on weston"
handle=/org/freedesktop/portal/desktop/request/1_0/e2e
out=$(mktemp)
gdbus call --session --timeout 60 --dest "$BUS" --object-path "$OBJ" \
	--method org.freedesktop.impl.portal.FileChooser.OpenFile \
	"$handle" org.example.E2E '' 'e2e' '@a{sv} {}' >"$out" 2>&1 &
call=$!
sleep 3
if ! kill -0 "$call" 2>/dev/null; then
	wait "$call" || true
	fail "OpenFile returned before the dialog was closed: $(cat "$out")"
fi
echo "dialog open, request pending"
gdbus call --session --dest "$BUS" --object-path "$handle" \
	--method org.freedesktop.impl.portal.Request.Close >/dev/null ||
	fail "Request.Close failed"
for _ in $(seq 50); do
	kill -0 "$call" 2>/dev/null || break
	sleep 0.1
done
kill -0 "$call" 2>/dev/null && fail "OpenFile still pending 5s after Request.Close"
wait "$call" || true
echo "OpenFile after Close: $(cat "$out")"
[[ $(dbus NameHasOwner "$BUS") == '(true,)' ]] || fail "backend left the bus after the dialog"
[[ $(dbus GetConnectionUnixProcessID "$BUS" | sed -n 's/.*uint32 \([0-9]*\).*/\1/p') == "$pid" ]] ||
	fail "backend restarted during the dialog test"

step "all e2e checks passed"
