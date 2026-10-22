# guides

Personal how-to guides, written while actually doing the thing. All names, IPs
and passwords are examples, replace them with your own.

| Guide | What it covers |
|---|---|
| [Home server](home-server/setup-guide.md) | Raspberry Pi 4 home server: SATA boot, Samba, Paperless-ngx, Immich, a second Pi as dedicated ML server, Tailscale remote access, zswap and systemd-oomd against memory hangs, one-command maintenance and restart |
| [Arch Linux install](arch-install.md) | Encrypted Arch: LUKS2 + Btrfs, unified kernel image, systemd-boot, Secure Boot with own keys, TPM2 auto-unlock, zswap on a swap file, GNOME |
| [TLP on a coreboot ThinkPad T480](thinkpad-t480-tlp.md) | Power profiles switched from the GNOME menu via tlp-pd, CPU, wifi and charge threshold settings for both batteries |
| [TLP on a ThinkPad X270](thinkpad-x270-tlp.md) | Power profiles switched from the Plasma tray via tlp-pd, CPU settings, runtime PM and USB autosuspend for Ethernet, wifi and the LTE modem |
| [HDMI audio on Philips TVs](pipewire-hdmi-tv-audio.md) | WirePlumber rule that pins the HDMI output to S16LE stereo |
| [LUKS auto-unlock without a hardware TPM](swtpm-luks-autounlock.md) | systemd's software TPM (swtpm): encrypted state on the ESP, full revert path, recovery after firmware updates |
| [Ventoy USB stick](ventoy-usb/setup-guide.md) | One stick for Windows and Linux: Ventoy with hidden boot partition, LUKS partition, Debian Live with German keyboard, script for new Debian ISOs |

The Arch, swtpm and T480 TLP guides run on
[coreboot-t480](https://github.com/Amphero/coreboot-t480), coreboot with an
EDK2 UEFI payload for that machine.
