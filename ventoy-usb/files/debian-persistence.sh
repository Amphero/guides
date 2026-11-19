#!/usr/bin/env bash
# Creates USB/persistence/debian-live.dat, an ext4 image Debian Live
# mounts at boot. Only these folders persist:
#   /etc/NetworkManager/system-connections   Wi-Fi profiles of this machine
#   /etc/easyroam-certs                      eduroam certificates, if any
#   /usr/local                               tailscale, tailscaled
#   /etc/systemd/system                      tailscaled.service, changes only
#   /var/lib/tailscale                       Tailscale node
# Unencrypted, the Debian Live initramfs has no cryptsetup. Anyone with
# the stick can read the Wi-Fi passwords and keys.
#   run0 bash debian-persistence.sh

set -euo pipefail

LABEL=USB
SIZE_MB=1024
TS_VER=1.104.7

fail() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail "run as root"

U=$(findmnt -rno TARGET -S "LABEL=$LABEL" | head -1)
[ -n "$U" ] || fail "partition $LABEL is not mounted"
DAT="$U/persistence/debian-live.dat"
[ -e "$DAT" ] && fail "$DAT exists, delete it first to start over"

TMP=$(mktemp -d)
MNT="$TMP/mnt"
cleanup() {
    mountpoint -q "$MNT" && umount "$MNT"
    rm -rf "$TMP"
}
trap cleanup EXIT

# not in Debian, static build
T=tailscale_${TS_VER}_amd64.tgz
curl -fsSL -o "$TMP/$T" "https://pkgs.tailscale.com/stable/$T"
[ "$(sha256sum "$TMP/$T" | cut -d' ' -f1)" = "$(curl -fsSL "https://pkgs.tailscale.com/stable/$T.sha256" | tr -d '[:space:]')" ] \
    || fail "tailscale checksum mismatch"
tar -xzf "$TMP/$T" -C "$TMP"
TS="$TMP/tailscale_${TS_VER}_amd64"

mkdir -p "$U/persistence"
dd if=/dev/zero of="$DAT" bs=1M count="$SIZE_MB" status=none
mkfs.ext4 -q -L persistence "$DAT"
mkdir "$MNT"
mount -o loop "$DAT" "$MNT"

cat >"$MNT/persistence.conf" <<'EOF'
/etc/NetworkManager/system-connections source=nm
/etc/easyroam-certs source=easyroam-certs
/usr/local source=usr-local
/etc/systemd/system source=systemd-system,union
/var/lib/tailscale source=tailscale
EOF

install -d -m 0700 "$MNT/nm" "$MNT/tailscale"
n=0
for f in /etc/NetworkManager/system-connections/*.nmconnection; do
    grep -q '^type=wifi' "$f" || continue
    # interface-name ties the profile to this machine
    sed '/^interface-name=/d' "$f" >"$MNT/nm/${f##*/}"
    chmod 0600 "$MNT/nm/${f##*/}"
    n=$((n + 1))
done
echo "wifi profiles: $n"
if [ -d /etc/easyroam-certs ]; then
    cp -a /etc/easyroam-certs "$MNT/easyroam-certs"
    echo "easyroam certificates: $(find "$MNT/easyroam-certs" -type f | wc -l) files"
else
    install -d -m 0755 "$MNT/easyroam-certs"
fi

install -d "$MNT/usr-local/bin"
install -m 0755 "$TS/tailscale" "$TS/tailscaled" "$MNT/usr-local/bin/"
install -d "$MNT/systemd-system/multi-user.target.wants"
sed -e 's#/usr/sbin/tailscaled#/usr/local/bin/tailscaled#g' \
    -e 's#^EnvironmentFile=/etc/default/tailscaled#Environment=PORT=41641 FLAGS=#' \
    "$TS/systemd/tailscaled.service" >"$MNT/systemd-system/tailscaled.service"
ln -s ../tailscaled.service "$MNT/systemd-system/multi-user.target.wants/tailscaled.service"
echo "tailscale: $("$TS/tailscale" version | head -1)"

sync
echo "created $DAT"
