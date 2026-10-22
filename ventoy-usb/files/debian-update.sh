#!/usr/bin/env bash
# Run after putting a new Debian Live ISO on the stick: rebuilds the German
# boot menu (ventoy/debian/grub.cfg + live.cfg) from the newest ISO and points
# ventoy/ventoy.json at it.

set -euo pipefail

LABEL=USB
PARAMS='locales=de_DE.UTF-8 keyboard-layouts=de timezone=Europe/Berlin'
SUMS_URL=https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/SHA256SUMS

fail() { echo "error: $*" >&2; exit 1; }

command -v bsdtar  >/dev/null || fail "bsdtar missing (Arch: libarchive, Debian: libarchive-tools)"
command -v python3 >/dev/null || fail "python3 missing"

U=$(findmnt -rno TARGET -S "LABEL=$LABEL" 2>/dev/null | head -1 || true)
if [ -z "$U" ]; then
    [ -e "/dev/disk/by-label/$LABEL" ] || fail "no partition labelled $LABEL"
    udisksctl mount -b "/dev/disk/by-label/$LABEL" >/dev/null
    U=$(findmnt -rno TARGET -S "LABEL=$LABEL" | head -1)
fi

mapfile -t ISOS < <(cd "$U/ISO" && ls -1 debian-live-*-amd64-kde.iso 2>/dev/null | sort -V)
[ ${#ISOS[@]} -gt 0 ] || fail "no debian-live-*-amd64-kde.iso in $U/ISO"
NAME=${ISOS[-1]}
ISO="$U/ISO/$NAME"
echo "iso: $NAME"
[ ${#ISOS[@]} -gt 1 ] && printf 'older, can be deleted: %s\n' "${ISOS[@]:0:${#ISOS[@]}-1}"

SUM=$(curl -fsL --max-time 20 "$SUMS_URL" 2>/dev/null | awk -v n="$NAME" '$2==n {print $1}' || true)
if [ -n "$SUM" ]; then
    [ "$(sha256sum "$ISO" | cut -d' ' -f1)" = "$SUM" ] || fail "checksum mismatch"
    echo "checksum: ok"
else
    echo "checksum: not checked (offline or ISO no longer current)"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Kernel and initrd names stay as they are, Ventoy only hooks the initrd
# named in the original menu.
bsdtar -xOf "$ISO" boot/grub/grub.cfg | sed -E \
    -e "/^\s*linux\s+\/live\/vmlinuz/ s#\$# $PARAMS#" \
    -e 's#"Live system \(amd64\)"#"Live system (amd64, de)"#' > "$TMP/grub.cfg"
bsdtar -xOf "$ISO" isolinux/live.cfg | sed -E \
    -e "/^\s*append boot=live/ s#\$# $PARAMS#" \
    -e 's#\^Live system \(amd64\)#^Live system (amd64, de)#' > "$TMP/live.cfg"

grep -qF "$PARAMS" "$TMP/grub.cfg" && grep -qF "$PARAMS" "$TMP/live.cfg" \
    || fail "boot menu layout changed, nothing written"

mkdir -p "$U/ventoy/debian"
cp "$TMP/grub.cfg" "$TMP/live.cfg" "$U/ventoy/debian/"

J="$U/ventoy/ventoy.json" NAME="$NAME" python3 - <<'EOF'
import json, os
p = os.environ['J']
iso = '/ISO/' + os.environ['NAME']
j = json.load(open(p)) if os.path.exists(p) else {}

ctl = j.setdefault('control', [])
for e in ctl:
    if 'VTOY_DEFAULT_IMAGE' in e:
        e['VTOY_DEFAULT_IMAGE'] = iso
        break
else:
    ctl.append({'VTOY_DEFAULT_IMAGE': iso})

own = ('/ventoy/debian/grub.cfg', '/ventoy/debian/live.cfg')
j['conf_replace'] = [e for e in j.get('conf_replace', []) if e.get('new') not in own] + [
    {'iso': iso, 'org': '/boot/grub/grub.cfg', 'new': '/ventoy/debian/grub.cfg'},
    {'iso': iso, 'org': '/isolinux/live.cfg',  'new': '/ventoy/debian/live.cfg'},
]

with open(p, 'w') as f:
    f.write(json.dumps(j, indent=4) + '\n')
EOF
sync
echo "done, boot menu shows \"Live system (amd64, de)\""
