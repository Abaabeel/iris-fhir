#!/usr/bin/env bash
# Build the distributable LXC image from the provisioned container.
# MAINTAINER-side. End users do not run this — they run bin/lxc-import.sh.
#
#   Usage: ./bin/lxc-image-build.sh [container-name] [out-dir]
#     container-name default: iris-fhir
#     out-dir default: /root/lxc-dist
#     PARTSIZE env overrides the split size (default 1800M; GitHub caps release
#     assets at 2G per file)
#
# Requirements: root, lxc-utils, pigz, ~10 GB free on /
#
# The container MUST already be in the blessed state (seeded, OAuth client
# provisioned, TLS cert installed) AND on a STATIC IP in its netplan config;
# the script refuses to package a DHCP-configured container, because the whole
# stack keys on https://10.0.3.108:52774 (see LXC-DROPIN.md).
set -euo pipefail

NAME="${1:-iris-fhir}"
OUTDIR="${2:-/root/lxc-dist}"
PARTSIZE="${PARTSIZE:-1800M}"
SRC="/var/lib/lxc/$NAME"
R="$SRC/rootfs"

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -d "$R" ] || { echo "error: no container $NAME at $SRC" >&2; exit 1; }
command -v pigz >/dev/null || { echo "error: pigz not installed" >&2; exit 1; }
command -v lxc-stop >/dev/null || { echo "error: lxc-utils not installed" >&2; exit 1; }

# Guard: the container must be on a static IP, not DHCP.
if grep -q 'dhcp4' "$R/etc/netplan/10-lxc.yaml" 2>/dev/null; then
  echo "error: container still uses DHCP. Pin a static IP first (see LXC-DROPIN.md)." >&2
  exit 1
fi

# Stop cleanly if running (idempotent; a live snapshot of the DBs would be dirty).
if [ "$(lxc-info -n "$NAME" -s -H 2>/dev/null)" = "RUNNING" ]; then
  echo "stopping $NAME..."
  lxc-stop -n "$NAME"
  sleep 3
fi
[ "$(lxc-info -n "$NAME" -s -H 2>/dev/null)" = "STOPPED" ] || { echo "error: could not stop $NAME" >&2; exit 1; }

echo "trimming cruft (installer kit, apt caches, logs)..."
rm -rf "$R/opt/iris-kit"
rm -rf "$R/var/cache/apt" "$R/var/lib/apt/lists"
# Surgical mgr trim: only files IRIS regenerates at boot. A `*.log` glob here
# is a trap — it deletes journal.log (the journal HISTORY log), and a boot
# without it aborts: "NEXTJRN: failed to open journal log" -> single-user mode
# (hit twice on 2026-09-30, recovered via STURECOV option 8 both times).
rm -f "$R/opt/iris/mgr/messages.log" "$R/opt/iris/mgr/alerts.log" "$R/opt/iris/mgr/cconsole.log" 2>/dev/null || true
find "$R/opt/iris/httpd/logs" -type f -delete 2>/dev/null || true
find "$R/var/log" -type f -delete 2>/dev/null || true
find "$R/tmp" -type f -delete 2>/dev/null || true
chmod 600 "$R/etc/netplan/10-lxc.yaml" 2>/dev/null || true
# NOTE — deliberately NOT deleted, ever (verified the hard way 2026-09-30):
#   - IRIS.WIJ + journal files + journal.log: removing them makes IRIS believe
#     the last shutdown was abnormal and the next boot falls into
#     journal-recovery single-user mode. Ship them; they are the
#     clean-shutdown marker. The journal.log glob trap above explains journal.log.
#   - /var/log subdirectories: Apache refuses to start without /var/log/apache2
#     (AH02291). Only files inside /var/log are removed.
#   - ssh host keys: regenerate-on-boot is not guaranteed under systemd.

mkdir -p "$OUTDIR"
ARCHIVE="$OUTDIR/${NAME}-image.tar.gz"
echo "packaging $SRC -> $ARCHIVE (pigz -9, this takes a few minutes)..."
rm -f "$ARCHIVE" "$ARCHIVE.part"* "$ARCHIVE.sha256" "$OUTDIR/parts.sha256"
tar -C /var/lib/lxc --numeric-owner --use-compress-program='pigz -9' -cf "$ARCHIVE" "$NAME"

cd "$OUTDIR"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
split -b "$PARTSIZE" -d -a 2 "$ARCHIVE" "$ARCHIVE.part"
sha256sum "$ARCHIVE.part"* > "$OUTDIR/parts.sha256"
rm -f "$ARCHIVE.part.size_placeholder" 2>/dev/null || true

echo
echo "done. Deliverables in $OUTDIR:"
ls -lh "$OUTDIR" | awk '{print "  " $5, $9}'
echo
echo "next:"
echo "  1) upload the .partNN files + parts.sha256 to the GitHub release"
echo "  2) bash bin/lxc-import.sh github   (on an end-user host)"
echo "  3) lxc-start -n $NAME and re-verify before shipping:"
echo "     curl -sk https://10.0.3.108:52774/fhir/r4/metadata -o /dev/null -w '%{http_code}\n'"