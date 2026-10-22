# Ventoy USB stick with an encrypted partition

One stick for Windows and Linux machines:

| # | Name | Content | Visible on |
|---|---|---|---|
| 1 | `USB` | exFAT, ISOs and files | Windows, Linux, Debian Live |
| 2 | `VTOYEFI` | Ventoy boot files | nowhere |
| 3 | `SECURE` | LUKS2, 8 GiB | Linux only |

Debian Live boots on its own after 5 s, with German keyboard, locale and
timezone. Ventoy 1.1.18 or newer, older versions keep `USB` busy in the live
system.

Step 3 wipes the whole stick. Run everything as root, `/dev/sdX` is the
stick, check it with `lsblk -o NAME,SIZE,TRAN,MODEL` first.

---

## 1. Ventoy

```bash
V=1.1.18
curl -LO https://github.com/ventoy/Ventoy/releases/download/v$V/ventoy-$V-linux.tar.gz
curl -L https://github.com/ventoy/Ventoy/releases/download/v$V/sha256.txt | grep linux.tar.gz
sha256sum ventoy-$V-linux.tar.gz
tar xzf ventoy-$V-linux.tar.gz
```

## 2. Unmount

```bash
for p in /dev/sdX?; do udisksctl unmount -b "$p"; done
```

## 3. Install

```bash
cd ventoy-$V
./Ventoy2Disk.sh -I -g -s -L USB -r 8192 /dev/sdX
```

GPT, Secure Boot, label `USB`, 8 GiB left free at the end for `SECURE`.

## 4. Hide VTOYEFI

```bash
sfdisk --part-type  /dev/sdX 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B
sfdisk --part-attrs /dev/sdX 2 GUID:63
```

udisks ignores the EFI system partition type, so Dolphin and Nautilus don't
show it on any Linux machine. `GUID:63` means no drive letter on Windows.

## 5. SECURE

```bash
echo ',,CA7D7CCB-63ED-4C53-861C-1742536059CC' | sfdisk --append /dev/sdX
sfdisk --part-label /dev/sdX 3 SECURE
sfdisk --part-attrs /dev/sdX 3 GUID:63
cryptsetup luksFormat --type luks2 --label SECURE --pbkdf argon2id --pbkdf-memory 262144 /dev/sdX3
cryptsetup open /dev/sdX3 secure
mkfs.ext4 -L SECURE /dev/mapper/secure
cryptsetup close secure
```

Windows doesn't mount the LUKS type. `--pbkdf-memory 262144` needs 256 MiB
RAM to unlock instead of 1 GiB.

## 6. Debian Live

```bash
D=13.7.0
curl -LO https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-$D-amd64-kde.iso
curl -L https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/SHA256SUMS | grep "debian-live-$D-amd64-kde.iso$"
sha256sum debian-live-$D-amd64-kde.iso

udisksctl mount -b /dev/sdX1
mkdir -p /run/media/$USER/USB/{ISO,ventoy}
cp debian-live-$D-amd64-kde.iso /run/media/$USER/USB/ISO/
```

## 7. Ventoy settings

`/run/media/$USER/USB/ventoy/ventoy.json`:

```json
{
    "control": [
        { "VTOY_MENU_LANGUAGE": "de_DE" },
        { "VTOY_DEFAULT_SEARCH_ROOT": "/ISO" },
        { "VTOY_MENU_TIMEOUT": "5" },
        { "VTOY_SECONDARY_TIMEOUT": "5" }
    ],
    "theme": {
        "display_mode": "CLI"
    }
}
```

Text menu, only `/ISO` is searched. Step 8 adds the default image, together
with the 5 s timeouts the stick boots without a key press.

## 8. German keyboard in Debian Live

[`files/debian-update.sh`](files/debian-update.sh) copies the boot menu out of
the newest Debian ISO on the stick, appends
`locales=de_DE.UTF-8 keyboard-layouts=de timezone=Europe/Berlin` and points
Ventoy's `conf_replace` and default image at that ISO.

```bash
cp files/debian-update.sh /run/media/$USER/USB/ventoy/
bash /run/media/$USER/USB/ventoy/debian-update.sh
```

Needs `bsdtar` and `python3`. Run it again after every new Debian ISO, then
delete the old one.

Two things that break the boot if done by hand:

- Keep the kernel and initrd names exactly as in the ISO. `/live/initrd.img`
  and `/live/initrd.img-<version>` are the same file, but Ventoy only hooks
  the one named in the original menu, otherwise Debian ends in the
  `(initramfs)` shell.
- `*` in Ventoy paths matches exactly one character, so use the full ISO name.

## 9. Hide Windows folders on Linux

```bash
cd /run/media/$USER/USB
printf '%s\n' 'System Volume Information' '$RECYCLE.BIN' 'desktop.ini' 'Desktop.ini' \
  'Thumbs.db' 'autorun.inf' 'AUTORUN.INF' 'FOUND.000' 'FOUND.001' 'FOUND.002' \
  'msdownld.tmp' 'ehthumbs.db' 'ehthumbs_vista.db' 'RECYCLER' 'LOST.DIR' > .hidden
find . -mindepth 1 -type d -not -path './.Trash-*' -exec cp .hidden {}/ \;
echo ventoy >> .hidden
```

Dolphin and Nautilus hide every name listed in a folder's `.hidden`, Ctrl+H
shows them. One file per folder, no wildcards, new folders need a copy.

## 10. Check

```bash
sfdisk -d /dev/sdX
for p in 1 2 3; do udisksctl info -b /dev/sdX$p | grep -m1 HintIgnore; done
```

`HintIgnore` must be `true` only for partition 2. In Debian Live,
`cat /proc/cmdline` shows the German parameters and `USB` opens in Dolphin.

## Ventoy update

```bash
./Ventoy2Disk.sh -u /dev/sdX
```

Keeps all data, but rewrites VTOYEFI: repeat step 4.

## exFAT dirty flag

"Volume was not properly unmounted" on every mount stays until a check clears
it:

```bash
fsck.exfat -y /dev/sdX1
```
