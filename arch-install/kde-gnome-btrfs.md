# KDE and GNOME side by side on one Btrfs

Two Arch systems on one encrypted Btrfs, picked in the boot menu. A base
system is installed once, then copied, and each copy gets its own desktop.
Separate roots and homes, shared XDG folders, pacman cache and swap file.
No fstab, every mount sits on the kernel command line inside the UKI of its
system. Builds on the [Arch install guide](arch-install.md), steps that are
the same there are only referenced.

```
kde          / for KDE, var/log var/cache var/tmp srv nested
gnome        / for GNOME, same nesting
home-kde     /home for KDE
home-gnome   /home for GNOME
data/*       shared folders, one subvolume each
pkg          /var/cache/pacman/pkg
swap         /swap
```

Placeholders as in the Arch guide. `DIRS` are the folders both systems
share, named as xdg-user-dirs creates them for your locale:

```bash
DIRS="Bilder Dokumente Downloads Musik Projekte Videos"
```

---

## 1. Live system, partitions, encryption

Steps 1 to 3 of the Arch install guide.

## 2. Subvolumes

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

## 3. Mount the KDE root

```bash
mount -o subvol=/kde,compress=zstd:1,noatime /dev/mapper/root /mnt
mount -m -o subvol=/home-kde,noatime /dev/mapper/root /mnt/home
mount -m -o subvol=/pkg,noatime /dev/mapper/root /mnt/var/cache/pacman/pkg
mount -m -L ESP -o uid=0,gid=0,fmask=0077,dmask=0077 /mnt/efi
mkdir /mnt/swap
```

## 4. Base system

Step 5 of the Arch install guide, except for the kernel command line. Root
comes from `kde`, the other mounts from `40-mounts.conf`:

```bash
echo "root=gpt-auto rootflags=subvol=/kde,compress=zstd:1,noatime rw" > /mnt/etc/cmdline.d/30-root.conf
D=/dev/disk/by-designator/root
cat > /mnt/etc/cmdline.d/40-mounts.conf <<EOF
systemd.mount-extra=$D:/home:btrfs:subvol=/home-kde,noatime
systemd.mount-extra=$D:/swap:btrfs:subvol=/swap,noatime
systemd.mount-extra=$D:/var/cache/pacman/pkg:btrfs:subvol=/pkg,noatime
EOF
for d in $DIRS; do
  echo "systemd.mount-extra=$D:/home/<USERNAME>/$d:btrfs:subvol=/data/$d,noatime" >> /mnt/etc/cmdline.d/40-mounts.conf
done
```

No `:` in the mount options. `compress=zstd:1` splits the entry and systemd
drops it without an error, compression comes from the root mount anyway.

Step 6 of the Arch install guide (chroot, user). Still in the chroot,
step 7 with the UKI named after the system, these lines replace the preset
and `loader.conf` from there:

```bash
sed 's/^PRETTY_NAME=.*/PRETTY_NAME="Arch Linux (KDE)"/' /usr/lib/os-release > /etc/os-release-kde
cat > /etc/mkinitcpio.d/linux.preset <<'EOF'
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_uki="/efi/EFI/Linux/kde.efi"
default_options="--osrelease /etc/os-release-kde"
EOF
printf 'editor no\ndefault kde.efi\ntimeout 3\n' > /efi/loader/loader.conf
```

Step 8 without desktop and display manager, the rest is the same for both
systems:

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

Mount points for the shared folders:

```bash
U=$(awk -F: '$1=="<USERNAME>" {print $3}' /mnt/etc/passwd)
for d in $DIRS; do install -d -o $U -g $U /mnt/home/<USERNAME>/$d; done
```

## 5. Copy the base to `gnome`

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

## 6. KDE desktop

```bash
arch-chroot /mnt
pacman -S plasma-desktop plasma-login-manager bluedevil breeze-gtk discover kde-gtk-config \
  kdeplasma-addons kgamma kinfocenter kscreen ksshaskpass kwallet-pam kwrited \
  ocean-sound-theme plasma-disks plasma-nm plasma-pa plasma-thunderbolt plasma-welcome \
  plasma-workspace-wallpapers powerdevil xdg-desktop-portal-kde flatpak-kcm konsole \
  colord-kde dolphin dolphin-plugins drkonqi ffmpegthumbnailer ffmpegthumbs kdeconnect \
  kdegraphics-thumbnailers kdenetwork-filesharing kdialog kio-admin kio-gdrive kio-zeroconf \
  krdp kwin-x11 plasma-browser-integration plasma-keyboard plasma-vault plymouth-kcm \
  print-manager wacomtablet
systemctl enable plasmalogin.service
mkinitcpio -P
exit
umount -R /mnt
```

## 7. GNOME desktop

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

## 8. Secure Boot and TPM2

Step 10 of the Arch install guide, sign both UKIs instead of `Default.efi`:

```bash
run0 sbctl sign -s /efi/EFI/Linux/kde.efi
run0 sbctl sign -s /efi/EFI/Linux/gnome.efi
```

The LUKS enrollment is done once. Change `/etc/crypttab` and run
`mkinitcpio -P` in both systems. With the
[software TPM](../swtpm-luks-autounlock.md), both systems need its part 1,
including the `efi.automount` drop-in from step 4 d).

The other system from the running one:

```bash
run0 mount -m -o subvolid=5,noatime /dev/disk/by-designator/root /run/toplevel
run0 systemd-nspawn -D /run/toplevel/gnome --bind=/efi --bind=/var/cache/pacman/pkg
```

## 9. Update both systems

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
