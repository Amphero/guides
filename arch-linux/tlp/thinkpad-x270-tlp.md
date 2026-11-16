# TLP on a ThinkPad X270

i5-6300U on the Lenovo firmware (1.51), Intel 8260 wifi, Sierra EM7455 LTE
modem, SATA SSD, internal and external battery. Profiles are switched by hand,
Plasma's tray drives TLP through tlp-pd.

```bash
pacman -R power-profiles-daemon
pacman -S tlp tlp-pd ethtool
systemctl mask power-profiles-daemon systemd-rfkill.service systemd-rfkill.socket
systemctl enable --now tlp tlp-pd
```

tlp-pd replaces power-profiles-daemon. With `--noconfirm` pacman refuses the
swap and installs nothing, so remove it first.

Settings go in `/etc/tlp.d/01-x270.conf`, see the
[T480 guide](thinkpad-t480-tlp.md) for why.

```ini
TLP_AUTO_SWITCH=0
TLP_PROFILE_DEFAULT=BAL

CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_performance
CPU_ENERGY_PERF_POLICY_ON_SAV=power
CPU_HWP_DYN_BOOST_ON_AC=1
CPU_HWP_DYN_BOOST_ON_BAT=1
CPU_HWP_DYN_BOOST_ON_SAV=0
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=1
CPU_BOOST_ON_SAV=0
CPU_MAX_PERF_ON_AC=100
CPU_MAX_PERF_ON_BAT=100
CPU_MAX_PERF_ON_SAV=60

DEVICES_TO_DISABLE_ON_STARTUP="wwan"
```

`_ON_AC` is performance, `_ON_BAT` balanced, `_ON_SAV` power-saver. Switch
from the tray or with `tlp performance | balanced | power-saver`, check with
`tlp-stat -m`. A switch from the tray takes a second or two.

`intel_pstate` already runs active with `powersave`, driver and governor need
no setting.

TLP's defaults add runtime PM and USB autosuspend in balanced and power-saver.
Without TLP the host bridge, SATA controller, LPC bridge, I219 Ethernet and
wifi card sit at `on` and the EM7455 never suspends. With TLP all 17 PCI
devices are at `auto` and the modem is suspended. `wwan` is switched off at
startup because ModemManager is disabled, drop it to use LTE.

Measured on battery in balanced, Firefox open, three alternating rounds of
60 s: 6.81 W without TLP, 6.62 W with it, about 0.2 W. One round came out the
other way.

No DYTC, so no platform profile. SATA link power management is already
`med_power_with_dipm`, wifi power saving is on by default.

Charge thresholds stay in Plasma's battery settings. The EC keeps them, a TLP
setting would overwrite them at every boot.

Power limits stay with throttled, PL1 29 W on battery and 44 W on AC.
