# KDE and GNOME side by side on one Btrfs

Two Arch systems on one encrypted Btrfs, picked in the boot menu. A base
system is installed once, then copied, and each copy gets its own desktop.
Separate roots and homes, shared XDG folders, pacman cache and swap file.
No fstab, every mount sits on the kernel command line inside the UKI of its
system. LUKS2, unified kernel images, systemd-boot, Secure Boot with own
keys, TPM2 auto-unlock.

```
kde          / for KDE, var/log var/cache var/tmp srv nested
gnome        / for GNOME, same nesting
home-kde     /home for KDE
home-gnome   /home for GNOME
data/*       shared folders, one subvolume each
pkg          /var/cache/pacman/pkg
swap         /swap
```

Placeholders: `/dev/sdY` = target disk, `<SSID>`, `<USERNAME>`. `DIRS` are
the folders both systems share, named as xdg-user-dirs creates them for your
locale:

```bash
DIRS="Bilder Dokumente Downloads Musik Projekte Videos"
```

---

## 1. Live system

Write the ISO (device name via `lsblk`):

```bash
run0 dd bs=4M conv=fsync oflag=direct status=progress if=<ISO> of=/dev/sdY
```

German keymap and WLAN:

```bash
loadkeys de-latin1-nodeadkeys
iwctl station wlan0 connect <SSID>
ping -c 1 archlinux.org
```

## 2. Partitions and encryption

Optionally discard the whole SSD first. Overwriting does not reliably
erase flash (wear leveling), and LUKS goes on top anyway:

```bash
blkdiscard -f /dev/sdY
```

ESP + root, with GPT type codes so the system is auto-discoverable
(`ef00` = ESP, `8304` = Linux root x86-64):

```bash
sgdisk -Z \
  -n 1:0:+1G -t 1:ef00 -c 1:ESP \
  -N 2 -t 2:8304 -c 2:OS \
  /dev/sdY

cryptsetup luksFormat /dev/disk/by-partlabel/OS
cryptsetup \
  --allow-discards \
  --perf-no_read_workqueue \
  --perf-no_write_workqueue \
  --persistent \
  open /dev/disk/by-partlabel/OS root

mkfs.fat -F 32 -n ESP /dev/disk/by-partlabel/ESP
mkfs.btrfs -L SPOOL /dev/mapper/root
```

## 3. Subvolumes

```bash
mount -L SPOOL -o compress=zstd:1,noatime /mnt
btrfs subvolume create /mnt/{kde,home-kde,home-gnome,data,pkg,swap}
mkdir -p /mnt/kde/var
btrfs subvolume create /mnt/kde/{var/log,var/cache,var/tmp,srv}
for d in $DIRS; do btrfs subvolume create /mnt/data/$d; done
btrfs filesystem mkswapfile --size 16g /mnt/swap/swapfile    # about the RAM size
umount /mnt
```

Only `kde` gets installed, `gnome` is a copy of it later.

## 4. Mount the KDE root

```bash
mount -o subvol=/kde,compress=zstd:1,noatime /dev/mapper/root /mnt
mount -m -o subvol=/home-kde,noatime /dev/mapper/root /mnt/home
mount -m -o subvol=/pkg,noatime /dev/mapper/root /mnt/var/cache/pacman/pkg
mount -m -L ESP -o uid=0,gid=0,fmask=0077,dmask=0077 /mnt/efi
mkdir /mnt/swap
```

## 5. Base system

```bash
pacstrap -K /mnt \
  base linux linux-firmware intel-ucode \
  btrfs-progs sbctl tpm2-tss \
  reflector wireless-regdb bash-completion nano
```

Root entry in `/etc/crypttab`. `x-initrd.attach` makes mkinitcpio copy it
into the initramfs, where root gets unlocked:

```bash
echo "root UUID=$(lsblk -dno UUID /dev/disk/by-partlabel/OS) none x-initrd.attach" >> /mnt/etc/crypttab
```

Swap is zswap as in GNOME OS: pages get compressed in RAM, up to 35% of it
(`zswap.max_pool_percent` on the kernel command line), the cold ones go to
the swap file instead of the OOM killer. The swap file needs its own unit,
its size is fixed for good, see step 14. Then the journal in RAM, ntsync
for Wine/Proton, regulatory domain, resolved stub:

```bash
cat > /mnt/etc/systemd/system/swap-swapfile.swap <<EOF
[Swap]
What=/swap/swapfile

[Install]
WantedBy=swap.target
EOF

mkdir -p /mnt/etc/sysctl.d
cat > /mnt/etc/sysctl.d/99-zswap.conf <<EOF
vm.swappiness = 133
vm.watermark_scale_factor = 200
vm.watermark_boost_factor = 0
EOF

mkdir -p /mnt/etc/systemd/journald.conf.d
cat > /mnt/etc/systemd/journald.conf.d/settings.conf <<EOF
[Journal]
Storage=volatile
RuntimeMaxUse=50M
EOF

mkdir -p /mnt/etc/modules-load.d
echo ntsync > /mnt/etc/modules-load.d/ntsync.conf

echo 'WIRELESS_REGDOM="DE"' >> /mnt/etc/conf.d/wireless-regdom
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
```

Kernel command line, split into `cmdline.d` snippets. Root comes from `kde`,
the other mounts from `40-mounts.conf`:

```bash
mkdir -p /mnt/etc/cmdline.d
echo "root=gpt-auto rootflags=subvol=/kde,compress=zstd:1,noatime rw" > /mnt/etc/cmdline.d/30-root.conf
echo "quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3" > /mnt/etc/cmdline.d/10-silent-boot.conf
echo "mem_sleep_default=deep" > /mnt/etc/cmdline.d/30-sleep-mode.conf
echo "zswap.max_pool_percent=35" > /mnt/etc/cmdline.d/30-zswap.conf
# device-specific (here: ThinkPad X270), adjust or drop:
echo "psmouse.synaptics_intertouch=1" > /mnt/etc/cmdline.d/30-device.conf
D=/dev/disk/by-designator/root
cat > /mnt/etc/cmdline.d/40-mounts.conf <<EOF
systemd.mount-extra=$D:/home:btrfs:subvol=/home-kde,noatime
systemd.mount-extra=$D:/swap:btrfs:subvol=/swap,noatime
systemd.mount-extra=$D:/var/cache/pacman/pkg:btrfs:subvol=/pkg,noatime
EOF
for d in $DIRS; do
  echo "systemd.mount-extra=$D:/home/<USERNAME>/$d:btrfs:subvol=/data/$d,noatime,x-gvfs-hide,x-gvfs-trash" >> /mnt/etc/cmdline.d/40-mounts.conf
done
```

No `:` in the mount options. `compress=zstd:1` splits the entry and systemd
drops it without an error, compression comes from the root mount anyway.
`x-gvfs-hide` keeps GNOME from listing the shared folders as drives under
Other Locations. GLib refuses to trash on subvolume mounts, Nautilus only
offers to delete permanently there. `x-gvfs-trash` turns trash on, each
folder gets its own hidden `.Trash-1000`, Nautilus shows them as one trash.

Initramfs hooks (systemd-based, `sd-encrypt` for LUKS), then locale,
timezone and hostname interactively:

```bash
mkdir -p /mnt/etc/mkinitcpio.conf.d
cat > /mnt/etc/mkinitcpio.conf.d/hooks.conf <<EOF
HOOKS=(base systemd autodetect microcode keyboard sd-vconsole modconf kms block sd-encrypt filesystems)
EOF
systemd-firstboot --force --root=/mnt --setup-machine-id --prompt
```

## 6. Chroot, user, bootloader

systemd-boot plus a unified kernel image named after the system:

```bash
arch-chroot /mnt
hwclock --systohc
locale-gen
useradd -mG wheel,http <USERNAME>
passwd <USERNAME>

bootctl install
sbctl create-keys
sed 's/^PRETTY_NAME=.*/PRETTY_NAME="Arch Linux (KDE)"/' /usr/lib/os-release > /etc/os-release-kde
cat > /etc/mkinitcpio.d/linux.preset <<'EOF'
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_uki="/efi/EFI/Linux/kde.efi"
default_options="--osrelease /etc/os-release-kde"
EOF
mkinitcpio -P
rm /boot/initramfs*
printf 'editor no\ndefault kde.efi\ntimeout 3\n' > /efi/loader/loader.conf
```

## 7. Common packages

Everything without the desktop, the same for both systems:

```bash
pacman -S networkmanager tlp tlp-pd ethtool cups flatpak \
  pipewire-{pulse,jack,alsa,v4l2} gst-plugin-pipewire \
  gst-plugins-{good,bad,ugly} gst-libav gst-plugin-va \
  libde265 intel-media-driver alsa-utils \
  systemd-{resolvconf,ukify} git
systemctl mask power-profiles-daemon systemd-rfkill.service systemd-rfkill.socket
systemctl enable NetworkManager.service bluetooth.service tlp.service tlp-pd.service \
  cups.socket systemd-{oomd,boot-update,resolved,timesyncd}.service reflector.timer \
  swap-swapfile.swap
exit
```

TLP instead of power-profiles-daemon, tlp-pd serves the power profile switch
in GNOME and Plasma alike. Settings per machine in the
[T480](../tlp/thinkpad-t480-tlp.md) and [X270](../tlp/thinkpad-x270-tlp.md) guides.

Mount points for the shared folders:

```bash
U=$(awk -F: '$1=="<USERNAME>" {print $3}' /mnt/etc/passwd)
for d in $DIRS; do install -d -o $U -g $U /mnt/home/<USERNAME>/$d; done
```

## 8. Copy the base to `gnome`

A snapshot shows nested subvolumes as empty placeholders that can't be
written to, replace them first:

```bash
mount -m -o subvolid=5,noatime /dev/mapper/root /top
btrfs subvolume snapshot /top/kde /top/gnome
for d in var/log var/cache var/tmp srv; do
  rmdir /top/gnome/$d
  btrfs subvolume create /top/gnome/$d && chmod --reference=/top/kde/$d /top/gnome/$d
  cp -a --reflink=auto --one-file-system /top/kde/$d/. /top/gnome/$d/
done

G=/top/gnome
echo "root=gpt-auto rootflags=subvol=/gnome,compress=zstd:1,noatime rw" > $G/etc/cmdline.d/30-root.conf
sed -i 's#subvol=/home-kde,#subvol=/home-gnome,#' $G/etc/cmdline.d/40-mounts.conf
mv $G/etc/os-release-kde $G/etc/os-release-gnome
sed -i 's/(KDE)/(GNOME)/' $G/etc/os-release-gnome
sed -i 's/kde/gnome/g' $G/etc/mkinitcpio.d/linux.preset

install -d -m 700 -o $U -g $U /top/home-gnome/<USERNAME>
for d in $DIRS; do install -d -o $U -g $U /top/home-gnome/<USERNAME>/$d; done
umount /top
```

## 9. KDE desktop

```bash
arch-chroot /mnt
pacman -S plasma-desktop plasma-login-manager bluedevil breeze-gtk discover kde-gtk-config \
  kdeplasma-addons kgamma kinfocenter kscreen ksshaskpass kwallet-pam kwrited \
  ocean-sound-theme plasma-disks plasma-nm plasma-pa plasma-thunderbolt plasma-welcome \
  plasma-workspace-wallpapers powerdevil xdg-desktop-portal-kde flatpak-kcm konsole \
  colord-kde dolphin dolphin-plugins drkonqi ffmpegthumbnailer ffmpegthumbs kdeconnect \
  kdegraphics-thumbnailers kdenetwork-filesharing kdialog kio-admin kio-gdrive kio-zeroconf \
  krdp plasma-browser-integration plasma-keyboard plasma-vault plymouth-kcm print-manager \
  wacomtablet kate okular gwenview haruna
systemctl enable plasmalogin.service
mkinitcpio -P
exit
umount -R /mnt
```

## 10. GNOME desktop

```bash
mount -o subvol=/gnome,compress=zstd:1,noatime /dev/mapper/root /mnt
mount -o subvol=/home-gnome,noatime /dev/mapper/root /mnt/home
mount -o subvol=/pkg,noatime /dev/mapper/root /mnt/var/cache/pacman/pkg
mount -L ESP -o uid=0,gid=0,fmask=0077,dmask=0077 /mnt/efi
arch-chroot /mnt
pacman -S gdm gnome-shell gnome-session gnome-settings-daemon gnome-control-center \
  gnome-keyring gnome-menus gnome-backgrounds gnome-color-manager gnome-disk-utility gnome-software \
  gnome-console gnome-remote-desktop gnome-user-docs gnome-user-share nautilus yelp orca tecla \
  malcontent rygel grilo-plugins gvfs gvfs-{afc,dnssd,goa,gphoto2,mtp,nfs,onedrive,smb,wsdd} \
  xdg-desktop-portal-{gnome,gtk} xdg-user-dirs-gtk evolution-data-server ibus
systemctl enable gdm.service
mkinitcpio -P
exit
umount -R /mnt
cryptsetup close root
systemctl reboot
```

The boot menu shows "Arch Linux (KDE)" and "Arch Linux (GNOME)", KDE is the
default.

## 11. Secure Boot and TPM2

Secure Boot with own keys protects the boot chain; TPM2 then unlocks the
disk automatically. The unlock is bound to the Secure Boot state (PCR 7),
if that changes, the LUKS passphrase is required at boot. In KDE:

```bash
run0 sbctl enroll-keys -m    # -m keeps Microsoft keys; -t adds TPM eventlog
run0 sbctl sign -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
run0 sbctl sign -s /efi/EFI/Linux/kde.efi
run0 sbctl sign -s /efi/EFI/Linux/gnome.efi
run0 bootctl install
systemctl reboot --firmware-setup    # enable Secure Boot in the UEFI menu
```

After the reboot, bind the LUKS slot to the TPM, once for both systems:

```bash
run0 systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/OS
```

Then in both systems the root entry in `/etc/crypttab` becomes
`none x-initrd.attach,tpm2-device=auto`, followed by `mkinitcpio -P`.

Don't drop `--tpm2-pcrs=7`: since systemd 258 the default is no PCRs at
all, and then the TPM hands out the key even with Secure Boot turned off.
A Secure Boot database update (e.g. dbx via fwupd) changes PCR 7. Enter
the passphrase once, then re-enroll, as two separate commands:

```bash
run0 systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/OS
run0 systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/OS
```

No hardware TPM in the machine? With the
[software TPM](../swtpm-luks-autounlock.md), both systems need its part 1,
including the `efi.automount` drop-in from step 4 d).

The other system from the running one:

```bash
run0 mount -m -o subvolid=5,noatime /dev/disk/by-designator/root /run/toplevel
run0 systemd-nspawn -D /run/toplevel/gnome --bind=/efi --bind=/var/cache/pacman/pkg
```

## 12. Update both systems

A pacman hook updates the other system after every upgrade, through the
shared cache. In both systems:

```bash
cat > /etc/pacman.d/hooks/zz-update-other.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Updating the other system...
When = PostTransaction
Exec = /usr/local/bin/update-other
EOF

cat > /usr/local/bin/update-other <<'EOF'
#!/bin/bash
systemd-detect-virt --container -q && exit 0
case "$(findmnt -no FSROOT /)" in
  /kde) OTHER=gnome ;; /gnome) OTHER=kde ;; *) exit 0 ;;
esac
T=/run/update-other
mkdir -p $T && mount -o subvolid=5,noatime /dev/disk/by-designator/root $T || exit 0
trap 'umount $T; rmdir $T' EXIT
echo "updating $OTHER, log in /var/log/update-other.log"
systemd-nspawn -q -D $T/$OTHER --bind=/efi --bind=/var/cache/pacman/pkg --pipe \
  pacman -Syu --noconfirm >>/var/log/update-other.log 2>&1 || echo "update of $OTHER failed"
exit 0
EOF
chmod 755 /usr/local/bin/update-other
```

Inside the container the hook does nothing, so it doesn't loop.

Flatpaks are installed per home and updated per system, each desktop only
shows its own apps.

## 13. Search index in GNOME

LocalSearch doesn't descend into mount points below `$HOME`, GNOME Music and
the search don't see the shared folders. After the first GNOME login:

```bash
L="'&DESKTOP', '&TEMPLATES', '&PUBLIC_SHARE'"
for d in $DIRS; do L="$L, '\$HOME/$d'"; done
gsettings set org.freedesktop.Tracker3.Miner.Files index-recursive-directories "[$L]"
gsettings set org.freedesktop.Tracker3.Miner.Files index-single-directories "['\$HOME']"
localsearch reset -s
```

`$HOME` only non-recursive, otherwise the folders below it are dropped.
Baloo in KDE indexes the mounts as is.

## 14. When the RAM changes

Btrfs needs the swap file preallocated, so it keeps its size. This rebuilds it
from `MemTotal`, and the `&&` chain stops before the `rm` if swap is still in
use:

```bash
run0 bash -c 'systemctl stop swap-swapfile.swap && rm -f /swap/swapfile && btrfs filesystem mkswapfile --size $(( ($(grep -m1 MemTotal /proc/meminfo | tr -dc 0-9) + 1048575) / 1048576 ))g /swap/swapfile && systemctl start swap-swapfile.swap && swapon --show'
```
