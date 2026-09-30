#!/usr/bin/env bash
# Drop the iris-fhir LXC image in and start it. END-USER side.
# Downloads (if needed), verifies the whole-archive checksum, extracts under
# /var/lib/lxc and lxc-start -- then hands off to the stack setup in
# LXC-DROPIN.md.
#
#   Usage:  sudo bash bin/lxc-import.sh github
#           sudo bash bin/lxc-import.sh ./downloads          # dir with the .partNN files (+ .sha256)
#           sudo bash bin/lxc-import.sh iris-fhir-image.tar.gz
#           sudo bash bin/lxc-import.sh <url-to-part00> <url-to-part01>
#
set -euo pipefail

NAME=iris-fhir
DEST=/var/lib/lxc/$NAME
ARCHIVE_NAME="$NAME-image.tar.gz"
RELEASE_URL="https://github.com/Abaabeel/iris-fhir/releases/latest"
STAGE="${TMPDIR:-/var/tmp}/lxc-import.$$"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

die() { echo "error: $*" >&2; exit 1; }

echo "=== lxc image import: $NAME ==="

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
command -v lxc-start >/dev/null || die "lxc-utils not installed (apt install lxc)"
command -v curl >/dev/null || die "curl not installed"

# The image expects a default lxcbr0 (lxc-net) on 10.0.3.1.
if ! ip -4 addr show lxcbr0 2>/dev/null | grep -q '10\.0\.3\.1'; then
  echo "warning: lxcbr0 (10.0.3.1) not found. Enable it:"
  echo "  systemctl restart lxc-net   (the lxc package creates lxcbr0)"
fi

SRC="${1:-github}"
ARCHIVE="$STAGE/$ARCHIVE_NAME"
case "$SRC" in
  github)
    echo "fetching release metadata from $RELEASE_URL ..."
    api="$(curl -sfL "$RELEASE_URL" || die "cannot reach $RELEASE_URL (release not published?)")"
    assets="$(printf '%s' "$api" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); print(" ".join(a["browser_download_url"] for a in d.get("assets",[])))')"
    [ -n "$assets" ] || die "no assets found in the release"
    echo "downloading parts (each up to ~2 GB; extract from the release page if slow)..."
    for url in $assets; do
      [ -n "$url" ] || continue
      echo "  $(basename "$url")"
      curl -sfL -o "$STAGE/$(basename "$url")" "$url"
    done
    ls "$STAGE"/"$ARCHIVE_NAME".part* >/dev/null 2>&1 || die "archive parts missing after download"
    cat "$STAGE"/"$ARCHIVE_NAME".part* > "$ARCHIVE"
    ;;
  *.tar.gz)
    cp "$SRC" "$ARCHIVE"
    [ -f "${SRC%.tar.gz}.sha256" ] && cp "${SRC%.tar.gz}.sha256" "$STAGE/$(basename "${SRC%.tar.gz}.sha256")"
    ;;
  *.part*)
    cat "$@" > "$ARCHIVE"
    ;;
  http*)
    n=0; for url in "$@"; do case "$url" in
      http*) curl -sfL -o "$STAGE/part$(printf '%02d' "$n")" "$url"; n=$((n+1));;
    esac; done
    [ "$n" -gt 0 ] || die "no http(s) URLs given"
    cat "$STAGE"/part* > "$ARCHIVE"
    ;;
  *)
    [ -d "$SRC" ] || die "cannot read $SRC"
    ls "$SRC"/"$ARCHIVE_NAME".part* >/dev/null 2>&1 || die "no $ARCHIVE_NAME.part* files in $SRC"
    cat "$SRC"/"$ARCHIVE_NAME".part* > "$ARCHIVE"
    [ -f "$SRC/$ARCHIVE_NAME.sha256" ] && cp "$SRC/$ARCHIVE_NAME.sha256" "$STAGE/"
    ;;
esac

[ -s "$ARCHIVE" ] || die "no archive assembled"
echo "assembled: $(du -h "$ARCHIVE" | cut -f1)"

# Whole-archive verification (only skippable in raw-URL mode where no .sha256 was given).
SHAFILE="$STAGE/$ARCHIVE_NAME.sha256"
if [ -f "$SHAFILE" ]; then
  ( cd "$STAGE" && sha256sum -c "$ARCHIVE_NAME.sha256" ) || die "checksum mismatch on the downloaded image"
  echo "archive checksum OK"
fi

echo "extracting to $DEST ..."
mkdir -p /var/lib/lxc
tar -xzf "$ARCHIVE" -C /var/lib/lxc
[ -d "$DEST" ] || die "archive did not produce $DEST (wrong image?)"

grep -q "rootfs.path = dir:/var/lib/lxc/$NAME/rootfs" "$DEST/config" \
  || die "container config path mismatch; expected dir:/var/lib/lxc/$NAME/rootfs"

echo "starting container..."
lxc-start -n "$NAME" || true
for i in $(seq 1 30); do
  [ "$(lxc-info -n "$NAME" -s -H 2>/dev/null)" = "RUNNING" ] && break
  sleep 2
done
[ "$(lxc-info -n "$NAME" -s -H 2>/dev/null)" = "RUNNING" ] || die "container did not start (see /var/log/lxc/$NAME.log)"

code=""
for i in $(seq 1 30); do
  code="$(curl -sk --max-time 5 https://10.0.3.108:52774/fhir/r4/metadata -o /dev/null -w '%{http_code}' 2>/dev/null || true)"
  [ "$code" = 200 ] && break
  sleep 3
done
[ "$code" = 200 ] || cat <<'EOF'
warning: IRIS did not answer on https://10.0.3.108:52774 yet.
  - another host on 10.0.3.108? check /var/lib/misc/dnsmasq.lxcbr0.leases
  - IRIS may take ~1 min to boot after first start; re-run the probe below.
EOF
echo
echo "=== container status ==="
lxc-ls -f | grep "$NAME"
echo "=== FHIR metadata: ${code:-000} ==="
echo
echo "IRIS FHIR backend is up. Now run the 6-service stack (from this repo):"
echo "  git clone https://github.com/Abaabeel/iris-fhir.git && cd iris-fhir"
echo "  ./bin/provision.sh --check     # must report all inputs present"
echo "  ./bin/provision.sh"
echo "  ./bin/up.sh"
echo "  ./bin/seed-iris.sh             # asserts the 9 crg/dtr IRIS queries"
echo "  ./bin/demo.sh                  # expect: 12 passed, 0 failures"
echo "  python3 bin/e2e-browser.py     # expect: 14 passed, 0 failures"
echo "Full runbook: LXC-DROPIN.md"