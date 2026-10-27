# KDE and GNOME side by side on one Btrfs

Two Arch systems on one encrypted Btrfs, picked in the boot menu. Each has
its own root and home, the XDG folders, the pacman cache and the swap file
are shared. No fstab, every mount sits on the kernel command line inside the
UKI of its system. Starts from a system installed with the
[Arch install guide](arch-install.md) (here with KDE) and runs from that
system, no live USB.

```
kde          / for KDE, var/log var/cache var/tmp srv nested
gnome        / for GNOME, same nesting
home-kde     /home for KDE
home-gnome   /home for GNOME
data/*       shared folders, one subvolume each
pkg          /var/cache/pacman/pkg
swap         /swap
```

Run everything as root. The top level is only mounted when needed:

```bash
T=/run/toplevel DEV=/dev/disk/by-designator/root
mkdir -p $T && mount -o subvolid=5,noatime $DEV $T
```

A snapshot shows nested subvolumes as empty placeholders that can't be
written to. Replace them with `rmdir` before copying anything in.

---

## 1. Move the running system into `kde`

Right before the reboot, changes to `/etc` and `/var` after the snapshot
don't make it into `kde`. `/var` becomes part of the root, so the pacman
database stays with `/usr`:

```bash
btrfs subvolume snapshot / /kde
for d in var home swap; do rmdir /kde/$d; mkdir /kde/$d; chmod --reference=/$d /kde/$d; done
cp -a --reflink=auto --one-file-system /var/. /kde/var/
for d in log cache tmp lib/machines lib/portables; do rmdir /kde/var/$d 2>/dev/null; done
for d in var/log var/cache var/tmp srv; do
  [ -d /kde/$d ] && rmdir /kde/$d
  btrfs subvolume create /kde/$d && chmod --reference=/$d /kde/$d
  cp -a --reflink=auto --one-file-system /$d/. /kde/$d/
done
find /kde/var/cache/pacman/pkg -mindepth 1 -delete
btrfs subvolume create /pkg
cp -a --reflink=auto /var/cache/pacman/pkg/. /pkg/
```

Mounts, name in the boot menu, own UKI:

```bash
echo "root=gpt-auto rootflags=subvol=/kde,compress=zstd:1,noatime rw" > /kde/etc/cmdline.d/30-root.conf
cat > /kde/etc/cmdline.d/40-mounts.conf <<EOF
systemd.mount-extra=$DEV:/home:btrfs:subvol=/home,noatime
systemd.mount-extra=$DEV:/swap:btrfs:subvol=/swap,noatime
systemd.mount-extra=$DEV:/var/cache/pacman/pkg:btrfs:subvol=/pkg,noatime
EOF
sed 's/^PRETTY_NAME=.*/PRETTY_NAME="Arch Linux (KDE)"/' /usr/lib/os-release > /kde/etc/os-release-kde
cat > /kde/etc/mkinitcpio.d/linux.preset <<'EOF'
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_uki="/efi/EFI/Linux/kde.efi"
default_options="--osrelease /etc/os-release-kde"
EOF
systemd-nspawn -q -D /kde --bind=/efi mkinitcpio -P
printf 'editor no\ndefault kde.efi\ntimeout 3\n' > /efi/loader/loader.conf
bootctl set-default ""
reboot
```

No `:` in the mount options. `compress=zstd:1` splits the entry and systemd
drops it without an error, compression comes from the root mount anyway.
Check new lines before every reboot, each mount must show up:

```bash
G=$(mktemp -d) && mkdir $G/{n,e,l}
SYSTEMD_PROC_CMDLINE="$(cat /kde/etc/cmdline.d/*.conf | tr '\n' ' ')" SYSTEMD_FSTAB=/dev/null \
  /usr/lib/systemd/system-generators/systemd-fstab-generator $G/n $G/e $G/l
ls $G/n/local-fs.target.requires/
```

`bootctl set-default ""` clears an entry picked with `d` in the boot menu,
it overrides `loader.conf`. The old `Default.efi` still boots the old system.

## 2. Rename home, clear the top level

Booted into `kde`:

```bash
mv $T/home $T/home-kde
sed -i 's#subvol=/home,#subvol=/home-kde,#' /etc/cmdline.d/40-mounts.conf
mkinitcpio -P && reboot
```

After that boot, only `kde`, `home-kde`, `pkg` and `swap` stay:

```bash
for s in var/lib/machines var/lib/portables var/log var/cache var/tmp var srv; do btrfs subvolume delete $T/$s; done
for d in bin boot etc lib lib64 opt root sbin usr mnt dev proc run sys tmp efi; do rm -rf --one-file-system $T/$d; done
rm /efi/EFI/Linux/Default.efi
```

## 3. Shared folders

One subvolume per folder, mounted at the same path in both homes. Close
the apps that use them first.

```bash
H=/home/<USERNAME>
btrfs subvolume create $T/data
for d in Bilder Videos Musik Dokumente Projekte Downloads; do
  btrfs subvolume create $T/data/$d
  chown --reference=$H/$d $T/data/$d && chmod --reference=$H/$d $T/data/$d
  cp -a --reflink=auto --one-file-system $H/$d/. $T/data/$d/
  diff -rq $H/$d $T/data/$d || break
  mv $H/$d $H/.$d-old && mkdir $H/$d
  chown --reference=$H/.$d-old $H/$d && chmod --reference=$H/.$d-old $H/$d
  echo "systemd.mount-extra=$DEV:$H/$d:btrfs:subvol=/data/$d,noatime" >> /etc/cmdline.d/40-mounts.conf
done
mkinitcpio -P && reboot
```

Delete the `.*-old` folders once the mounts are there after the reboot.

## 4. GNOME

```bash
G=$T/gnome
btrfs subvolume snapshot $T/kde $G
for d in var/lib/machines var/lib/portables var/log var/cache var/tmp srv; do rmdir $G/$d 2>/dev/null; done
for d in var/log var/cache var/tmp srv; do
  btrfs subvolume create $G/$d && chmod --reference=$T/kde/$d $G/$d
  cp -a --reflink=auto --one-file-system $T/kde/$d/. $G/$d/
done

btrfs subvolume create $T/home-gnome
install -d -m 700 -o <USERNAME> -g <USERNAME> $T/home-gnome/<USERNAME>
for d in Bilder Videos Musik Dokumente Projekte Downloads .config; do
  install -d -o <USERNAME> -g <USERNAME> $T/home-gnome/<USERNAME>/$d
done
cp -a $H/.config/user-dirs.{dirs,locale} $T/home-gnome/<USERNAME>/.config/

echo "root=gpt-auto rootflags=subvol=/gnome,compress=zstd:1,noatime rw" > $G/etc/cmdline.d/30-root.conf
sed 's#subvol=/home-kde,#subvol=/home-gnome,#' /etc/cmdline.d/40-mounts.conf > $G/etc/cmdline.d/40-mounts.conf
rm $G/etc/os-release-kde
sed 's/^PRETTY_NAME=.*/PRETTY_NAME="Arch Linux (GNOME)"/' /usr/lib/os-release > $G/etc/os-release-gnome
sed -i 's/kde/gnome/g' $G/etc/mkinitcpio.d/linux.preset
```

Packages in a container. GNOME goes in first, so the KDE removal leaves
everything GNOME needs. Look at `-Rsp` before removing:

```bash
ns() { systemd-nspawn -q -D $G --bind=/efi --bind=/var/cache/pacman/pkg --pipe "$@"; }
ns pacman -Syu --needed gdm gnome-shell gnome-session gnome-settings-daemon gnome-control-center \
  gnome-keyring gnome-menus gnome-backgrounds gnome-color-manager gnome-disk-utility gnome-software \
  gnome-console gnome-remote-desktop gnome-user-docs gnome-user-share nautilus yelp orca tecla \
  malcontent rygel grilo-plugins gvfs gvfs-{afc,dnssd,goa,gphoto2,mtp,nfs,onedrive,smb,wsdd} \
  xdg-desktop-portal-{gnome,gtk} xdg-user-dirs-gtk evolution-data-server ibus
ns pacman -D --asexplicit bluez flatpak plymouth which xdg-user-dirs noto-fonts-emoji
ns pacman -Rsp <KDE packages>
systemctl --root=$G disable sddm.service
ns pacman -Rns <KDE packages>
systemctl --root=$G enable gdm.service
rm -rf $G/etc/sddm.conf.d
ns mkinitcpio -P
systemctl reboot --boot-loader-entry=gnome.efi
```

Flatpaks are per home. Either install them again in GNOME, or copy
`~/.local/share/flatpak` with `cp -a --reflink=auto` into `home-gnome` and
uninstall the KDE apps there.

With the [software TPM](../swtpm-luks-autounlock.md), both roots need the
`efi.automount` drop-in from step 4 d).

## 5. Update both systems

A pacman hook updates the other root after every upgrade, through the
shared cache. In both roots:

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

Inside the container the hook does nothing, so it doesn't loop. Flatpaks
are updated per system.
