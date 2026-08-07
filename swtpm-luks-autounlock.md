# LUKS auto-unlock without a hardware TPM (swtpm)

systemd 261 ships a software TPM (`systemd-tpm2-swtpm`) for machines
without a hardware TPM. Its state lives AES-encrypted on the ESP, keyed by
a boot secret that only the signed UKI can obtain in pre-boot. That is
enough to auto-unlock LUKS at boot. The passphrase stays as fallback, and
part 2 reverts everything.

Security in one sentence: this protects against disk theft and tampered
bootloaders, but not against someone who just powers on your laptop and
lets it boot (set a PIN in step 6 for that). The protection comes from the
state encryption, not from PCRs (a software TPM measures nothing, all PCRs
are 0). systemd itself calls the feature a "lower-security fallback".

Prerequisites, must already work (the [Arch install guide](arch-install.md)
ends exactly here):

- systemd >= 261
- LUKS2 root, systemd-boot + UKI, mkinitcpio with the `systemd` and
  `sd-encrypt` hooks
- Secure Boot active (e.g. via `sbctl`)
- A pre-boot RNG. Normal UEFI firmware has one; coreboot needs the RngDxe
  module in the payload (see
  [custom-coreboot-t480](https://github.com/Amphero/custom-coreboot-t480)
  for a T480 build that ships it), otherwise the swtpm state stays
  unencrypted and the whole thing is pointless.

Run everything as root.

---

## Part 1: enable

### 1. Packages

```
pacman -S swtpm tpm2-tools
```

### 2. Kernel command line

```
echo "systemd.tpm2_software_fallback=1 systemd.tpm2_wait=0" > /etc/cmdline.d/30-tpm.conf
```

The service only starts with `tpm2_software_fallback=1` (the feature is
gated). `tpm2_wait=0` stops systemd from waiting for a hardware TPM that
doesn't exist.

### 3. swtpm into the initramfs

The swtpm must already run in the initrd, before cryptsetup unlocks root.
Arch has no official integration for that, so: own install hook.

```bash
cat > /etc/initcpio/install/sd-tpm2-swtpm <<'EOF'
#!/bin/bash
build() {
    add_module tpm_vtpm_proxy
    add_module vfat
    add_module nls_cp437
    add_module nls_iso8859-1

    add_binary /usr/lib/systemd/systemd-tpm2-swtpm
    add_binary /usr/lib/systemd/system-generators/systemd-tpm2-generator

    add_binary swtpm
    add_binary swtpm_ioctl
    add_binary swtpm_setup
    add_binary swtpm_localca
    add_binary swtpm_cert
    add_binary certtool

    add_file /etc/swtpm_setup.conf
    add_file /etc/swtpm-localca.conf
    add_file /etc/swtpm-localca.options
    add_dir /var/lib/swtpm-localca

    add_systemd_unit systemd-tpm2-swtpm.service
    add_systemd_unit tpm2.target
    add_systemd_unit 'modprobe@.service'
}
help() {
    echo "Adds systemd-tpm2-swtpm (software TPM) to the initramfs."
}
EOF
```

mkinitcpio drop-in (easy to delete on revert):

```bash
cat > /etc/mkinitcpio.conf.d/tpm2-swtpm.conf <<'EOF'
MODULES+=(tpm_vtpm_proxy)
FILES+=(/etc/systemd/system/systemd-cryptsetup@.service.d/10-tpm2-swtpm-order.conf)
EOF
```

Then by hand: add the `sd-tpm2-swtpm` hook to your `HOOKS=` line, after
`systemd`, before `sd-encrypt`:

```
HOOKS=(base systemd sd-tpm2-swtpm autodetect microcode keyboard sd-vconsole modconf kms block sd-encrypt filesystems fsck)
```

### 4. systemd unit fixes

The swtpm runs twice: once in the initrd (becomes `tpm0`) and once in the
host after switch-root (becomes `tpm1`, because `tpm0` is still taken).
That handoff breaks three things which have to be fixed by hand. All three
go through `systemctl edit`, so one `systemctl revert` undoes them later.

a) cryptsetup must wait for the TPM device, or it races the swtpm in the
initrd, logs "No TPM2 hardware discovered" and asks for the passphrase.
Gating on the service is not enough (it reports ready before udev has the
device), gate on the device unit:

```bash
systemctl edit --stdin systemd-cryptsetup@.service --drop-in=10-tpm2-swtpm-order <<'EOF'
[Unit]
Wants=systemd-tpm2-swtpm.service
After=systemd-tpm2-swtpm.service
Wants=dev-tpmrm0.device
After=dev-tpmrm0.device
EOF
```

b) `tpm2.target` statically wants `dev-tpm0.device`, which never appears
in the host (the swtpm is `tpm1` there), giving a 90 s job timeout every
boot. An empty `Wants=` in a drop-in does not reset the list, so replace
the whole unit:

```bash
systemctl edit --full --stdin tpm2.target <<'EOF'
[Unit]
Description=Trusted Platform Module
Documentation=man:systemd.special(7)
After=dev-tpmrm0.device dev-tpm0.device systemd-tpm2-swtpm.service
EOF
```

c) Clean shutdown, stop the swtpm before the ESP is unmounted:

```bash
systemctl edit --stdin systemd-tpm2-swtpm.service --drop-in=10-efi-mount-order <<'EOF'
[Unit]
RequiresMountsFor=/efi/loader/swtpm
EOF
```

d) Transitional workaround for "Failed unmounting EFI System Partition
(Early)" + "Connect failed" at boot. Fixed upstream in systemd PR #42944
(merged 2026-07-09), so this disappears with a future systemd update. The
one-liner checks that itself: it installs the workaround only while your
systemd lacks the fix, and removes it again once the fix has arrived.
Reboot after any reported change; "nothing to do" means nothing to do.

```bash
run0 bash -c 'set -e; u=/usr/lib/systemd/system/systemd-tpm2-swtpm.service; d=/etc/systemd/system/systemd-tpm2-swtpm.service.d/20-pr42944-initrd-stop.conf; m=/etc/mkinitcpio.conf.d/tpm2-swtpm.conf; if grep -q initrd-switch-root.target "$u"; then if [ -e "$d" ]; then rm "$d"; sed -i "/20-pr42944-initrd-stop/d" "$m"; systemctl daemon-reload; mkinitcpio -P; sbctl verify; echo "REMOVED: systemd now contains the fix itself, workaround reverted, please reboot"; else echo "OK: fix already in systemd, nothing to do"; fi; elif [ -e "$d" ]; then echo "OK: workaround already active (systemd lacks the fix)"; else printf "[Unit]\nConflicts=initrd-switch-root.target\nBefore=initrd-switch-root.target\n" | systemctl edit --stdin systemd-tpm2-swtpm.service --drop-in=20-pr42944-initrd-stop; echo "FILES+=($d)" >> "$m"; mkinitcpio -P; sbctl verify; echo "INSTALLED: workaround active, please reboot"; fi'
```

Check after the reboot (expected: `0`):

```
journalctl -b | grep -cE "Failed unmounting EFI System Partition \(Early\)|Connect failed"
```

### 5. Build, sign, first reboot

```
mkinitcpio -P
sbctl verify        # MUST show "is signed" for the UKI, otherwise do NOT reboot
reboot
```

Still enter the passphrase this boot. Then verify:

```
ls /sys/class/tpm/                        # a TPM device, usually tpm1
ls -l /run/systemd/stub/boot-secret       # must exist (32 bytes)
journalctl -b | grep -i "not encrypting"  # MUST be empty, else no pre-boot RNG
```

### 6. Enroll LUKS

```
systemd-cryptenroll --tpm2-device=list    # shows e.g. /dev/tpmrm1
systemd-cryptenroll --tpm2-device=/dev/tpmrm1 /dev/disk/by-partlabel/OS
```

Use the device from the first line explicitly, `auto` would look for the
nonexistent `tpmrm0` in the host. It asks for your LUKS passphrase. For
laptops consider `--tpm2-with-pin=yes` (PIN instead of full automatic).
Passphrase slot 0 stays either way.

Then add `tpm2-device=auto` to your root entry in
`/etc/crypttab.initramfs`:

```
root UUID=<your-luks-uuid> none tpm2-device=auto
```

`auto` is right here: this file acts in the initrd, where the swtpm is the
first TPM and the device is `tpmrm0`. Enrollment (host, tpmrm1) and unseal
(initrd, tpmrm0) share the same state on the ESP, so they are compatible.

```
mkinitcpio -P
sbctl verify
reboot
```

Success = no passphrase prompt. To confirm:

```
journalctl -b | grep -iE "Finished Cryptography Setup|No TPM2"
# expected: "Finished Cryptography Setup for root", NO "No TPM2 hardware discovered"
```

---

## Part 2: full revert

Keep the order; afterwards the system is exactly as before (passphrase
unlock).

1. Remove the TPM keyslot:
   ```
   systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/OS
   systemd-cryptenroll /dev/disk/by-partlabel/OS   # must only show "0 password"
   ```
2. Remove `tpm2-device=auto` from `/etc/crypttab.initramfs`.
3. Revert all systemd changes, one command:
   ```
   systemctl revert systemd-cryptsetup@.service tpm2.target systemd-tpm2-swtpm.service
   ```
4. Delete the config files:
   ```
   rm /etc/cmdline.d/30-tpm.conf
   rm /etc/initcpio/install/sd-tpm2-swtpm
   rm /etc/mkinitcpio.conf.d/tpm2-swtpm.conf
   ```
5. Remove `sd-tpm2-swtpm` from your `HOOKS=` line.
6. Build and reboot:
   ```
   mkinitcpio -P
   sbctl verify        # again: MUST show "is signed"
   reboot
   ```
7. Delete the TPM state from the ESP (only after the reboot, then no swtpm
   is running anymore):
   ```
   rm -rf /efi/loader/swtpm
   ```
8. Optional: `pacman -Rs swtpm tpm2-tools`

---

## After a firmware/BIOS update

A firmware reflash usually wipes the EFI NVRAM and with it the
`LoaderBootSecret` variable. The boot secret changes, the swtpm state on
the ESP can't be decrypted anymore:

```
swtpm: Verification of HMAC failed. Data integrity is compromised
swtpm: Could not initialize libtpms
```

The swtpm stays down, cryptsetup falls back to the passphrase (data is
safe, slot 0 intact), but the old TPM enrollment is dead. Repair, booted
via passphrase, as root:

1. Check what survived:
   ```
   sbctl status                         # Secure Boot enabled? Setup Mode disabled?
   sbctl verify | grep Default.efi      # UKI still signed?
   ls -l /run/systemd/stub/boot-secret  # exists? then the new firmware has an RNG
   ```
   No boot secret: the new ROM lacks an RNG (coreboot: rebuild with
   RngDxe). Setup mode / keys gone: `sbctl enroll-keys` first. Usually
   both survive and only the swtpm state is dead.
2. Reset the dead state, bring up a fresh swtpm:
   ```
   rm -f /efi/loader/swtpm/tpm2-00.permall /efi/loader/swtpm/tpm2-00.volatilestate
   systemctl restart systemd-tpm2-swtpm.service
   ls /sys/class/tpm/                     # a device again, no HMAC error
   systemd-cryptenroll --tpm2-device=list # note the device (tpmrm0 or tpmrm1)
   ```
3. Wipe the old token, then enroll fresh, as TWO separate commands:
   ```
   systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/OS
   systemd-cryptenroll --tpm2-device=/dev/tpmrmN /dev/disk/by-partlabel/OS
   ```
   The combined command (`--wipe-slot=tpm2 --tpm2-device=...`) does not
   work: it reports "This PCR set is already enrolled, executing no
   operation" and keeps the dead token.
4. Reboot, auto-unlock is back. No `mkinitcpio -P` needed, nothing in the
   UKI changed.

One more warning for everyday life: deleting `/efi/loader/swtpm` means all
TPM keys are gone and auto-unlock is dead until you re-enroll. Be careful
with ESP cleanups.
