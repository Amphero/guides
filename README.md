# guides

Personal how-to guides, written while actually doing the thing. All names, IPs
and passwords are examples, replace them with your own.

| Guide | What it covers |
|---|---|
| [Home server](home-server/setup-guide.md) | Raspberry Pi 4 home server: SATA boot, Samba, Paperless-ngx, Immich, a second Pi as dedicated ML server, Tailscale remote access, one-command maintenance |
| [Arch Linux install](arch-install.md) | Encrypted Arch: LUKS2 + Btrfs, unified kernel image, systemd-boot, Secure Boot with own keys, TPM2 auto-unlock, GNOME |
| [HDMI audio on Philips TVs](pipewire-hdmi-tv-audio.md) | WirePlumber rule that pins the HDMI output to S16LE stereo |
| [LUKS auto-unlock without a hardware TPM](swtpm-luks-autounlock.md) | systemd's software TPM (swtpm): encrypted state on the ESP, full revert path, recovery after firmware updates |

Related project: [custom-coreboot-t480](https://github.com/Amphero/custom-coreboot-t480)
— coreboot with an EDK2 UEFI payload for the ThinkPad T480: Secure Boot with
your own keys, TPM 2.0, fully offline container build. The Arch and swtpm
guides above run on exactly this firmware.
