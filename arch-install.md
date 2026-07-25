# Arch Linux install

Encrypted Arch with LUKS2 + Btrfs, unified kernel image, systemd-boot,
Secure Boot with own keys, TPM2 auto-unlock, GNOME. No fstab, partitions
are found via GPT partition types and labels (`root=gpt-auto`).

Placeholders: `/dev/sdY` = target disk, `<SSID>`, `<USERNAME>`.

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

## 2. Partitioning

Optionally wipe the disk first:

```bash
shred -v -n 2 /dev/sdY
```

ESP + root, with GPT type codes so the system is auto-discoverable
(`ef00` = ESP, `8304` = Linux root x86-64):

```bash
sgdisk -Z \
  -n 1:0:+1G -t 1:ef00 -c 1:ESP \
  -N 2 -t 2:8304 -c 2:OS \
  /dev/sdY
```

## 3. Encrypt and format

```bash
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

## 4. Mount and subvolumes

Subvolumes for the noisy paths, no copy-on-write there (`chattr +C`):

```bash
mount -L SPOOL -o compress=zstd:1 /mnt
for sv in var var/log var/cache var/tmp srv home; do
  btrfs subvolume create /mnt/$sv && chattr +C /mnt/$sv
done
mount -m -L ESP -o uid=0,gid=0,fmask=0077,dmask=0077 /mnt/efi
```

## 5. Base system

```bash
pacstrap -K /mnt \
  base linux linux-firmware intel-ucode \
  btrfs-progs zram-generator sbctl tpm2-tss \
  reflector wireless-regdb bash-completion nano
```

Auto-unlock entry for the initramfs:

```bash
cat > /mnt/etc/crypttab.initramfs <<EOF
root UUID=$(lsblk -dno UUID /dev/disk/by-partlabel/OS) none
EOF
```

zram as swap, journal in RAM, regulatory domain, resolved stub:

```bash
echo "[zram0]" > /mnt/etc/systemd/zram-generator.conf

mkdir -p /mnt/etc/systemd/journald.conf.d
cat > /mnt/etc/systemd/journald.conf.d/settings.conf <<EOF
Storage=volatile
SystemMaxUse=50M
EOF

echo 'WIRELESS_REGDOM="DE"' >> /mnt/etc/conf.d/wireless-regdom
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
```

Kernel command line, split into `cmdline.d` snippets:

```bash
mkdir -p /mnt/etc/cmdline.d
echo "root=gpt-auto rootflags=compress=zstd:1 rw"                > /mnt/etc/cmdline.d/30-root.conf
echo "quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3" > /mnt/etc/cmdline.d/10-silent-boot.conf
echo "zswap.enabled=0"                                           > /mnt/etc/cmdline.d/20-disable-zswap.conf
echo "mem_sleep_default=deep"                                    > /mnt/etc/cmdline.d/30-sleep-mode.conf
# device-specific (here: InfinityBook 14 Pro v5), adjust or drop:
echo "psmouse.synaptics_intertouch=1 acpi_osi=Linux i915.enable_fbc=1 i915.enable_guc=2" > /mnt/etc/cmdline.d/30-device.conf
```

Initramfs hooks (systemd-based, `sd-encrypt` for LUKS):

```bash
mkdir -p /mnt/etc/mkinitcpio.conf.d
cat > /mnt/etc/mkinitcpio.conf.d/hooks.conf <<EOF
HOOKS=(base systemd autodetect microcode keyboard sd-vconsole modconf kms block sd-encrypt filesystems fsck)
EOF
```

Locale, timezone, hostname, interactively:

```bash
systemd-firstboot --force --root=/mnt --setup-machine-id --prompt
```

## 6. Chroot

```bash
arch-chroot /mnt
hwclock --systohc
locale-gen
useradd -mG wheel,http <USERNAME>
passwd <USERNAME>
```

## 7. Bootloader (UKI)

systemd-boot plus a unified kernel image, the kernel, initramfs and
command line end up as one signed EFI binary:

```bash
bootctl install
sbctl create-keys

cp /etc/mkinitcpio.d/linux.preset /etc/mkinitcpio.d/linux.preset.bak
cat > /etc/mkinitcpio.d/linux.preset <<EOF
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_uki="/efi/EFI/Linux/Default.efi"
EOF

mkinitcpio -P
rm /boot/initramfs*
echo "editor no" > /efi/loader/loader.conf
```

## 8. Desktop

```bash
pacman -S \
  gnome gdm networkmanager power-profiles-daemon cups \
  pipewire-{pulse,jack,alsa,v4l2} gst-plugin-pipewire \
  gst-plugins-{good,bad,ugly} gst-libav gst-plugin-va \
  libde265 intel-media-driver alsa-utils \
  systemd-{resolvconf,ukify} git

systemctl enable gdm.service NetworkManager.service bluetooth.service \
  cups.socket systemd-{oomd,boot-update,resolved}.service reflector.timer
```

## 9. Finish

```bash
exit
umount -R /mnt
cryptsetup close root
systemctl reboot
```

## 10. Secure Boot and TPM2

Secure Boot with own keys protects the boot chain; TPM2 then unlocks the
disk automatically. The unlock is bound to the Secure Boot state, if that
changes, the LUKS passphrase is required at boot.

```bash
run0 sbctl enroll-keys -m    # -m keeps Microsoft keys; -t adds TPM eventlog
run0 sbctl sign -s /usr/lib/systemd/boot/efi/systemd-bootx64.efi -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
run0 sbctl sign -s /efi/EFI/Linux/Default.efi
run0 bootctl install
systemctl reboot --firmware-setup    # enable Secure Boot in the UEFI menu
```

After the reboot, bind the LUKS slot to the TPM:

```bash
run0 systemd-cryptenroll --tpm2-device=auto /dev/disk/by-partlabel/OS
run0 nano /etc/crypttab.initramfs    # append: ... none tpm2-device=auto
run0 mkinitcpio -P && systemctl reboot
```

No hardware TPM in the machine? See
[LUKS auto-unlock without a hardware TPM](swtpm-luks-autounlock.md).
