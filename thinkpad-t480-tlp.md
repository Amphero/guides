# TLP on a coreboot ThinkPad T480

i7-8550U, coreboot instead of the Lenovo firmware, a Qualcomm QCNFA765 in
place of the stock wifi card, both battery bays filled. Profiles are switched
by hand, GNOME's power menu drives TLP through tlp-pd.

```bash
pacman -S tlp tlp-pd ethtool
systemctl mask power-profiles-daemon systemd-rfkill.service systemd-rfkill.socket
systemctl enable --now tlp tlp-pd
```

`ethtool` is not optional, `WOL_DISABLE` fails silently without it.

Settings go in `/etc/tlp.d/01-t480.conf`, not in `/etc/tlp.conf`, which
overrides every drop-in and collects `.pacnew` files. An image-based setup
cannot ship drop-ins from `/usr`, TLP only reads `/etc`, so symlink the
directory from tmpfiles: `L /etc/tlp.d - - - - ../usr/lib/tlp.d`.

```ini
TLP_AUTO_SWITCH=0
TLP_PROFILE_DEFAULT=BAL

CPU_DRIVER_OPMODE_ON_AC=active
CPU_DRIVER_OPMODE_ON_BAT=active
CPU_DRIVER_OPMODE_ON_SAV=active
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_SCALING_GOVERNOR_ON_SAV=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
CPU_ENERGY_PERF_POLICY_ON_SAV=power
CPU_HWP_DYN_BOOST_ON_AC=1
CPU_HWP_DYN_BOOST_ON_BAT=0
CPU_HWP_DYN_BOOST_ON_SAV=0
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=1
CPU_BOOST_ON_SAV=0
CPU_MAX_PERF_ON_AC=100
CPU_MAX_PERF_ON_BAT=100
CPU_MAX_PERF_ON_SAV=60

WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=off

SOUND_POWER_SAVE_ON_AC=10
SOUND_POWER_SAVE_ON_BAT=1

START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80
START_CHARGE_THRESH_BAT1=75
STOP_CHARGE_THRESH_BAT1=80

DEVICES_TO_DISABLE_ON_STARTUP="nfc wwan"
```

The suffixes are profile names, not power sources: `_ON_AC` is performance,
`_ON_BAT` balanced, `_ON_SAV` power-saver. Switch with
`tlp performance | balanced | power-saver`, check with `tlp-stat -m`.

`intel_pstate` runs active, where EPP does the throttling, so `powersave` plus
EPP `performance` gives full turbo at a low idle draw. coreboot caps the board
at PL1 15 W and PL2 18.75 W, so turbo only goes in power-saver. Wifi power
saving costs 8 ms and triples the jitter on the QCNFA765 for 0.3-1 W. Both
battery bays need their own thresholds.

No point adding `PCIE_ASPM`: coreboot sets up L1 plus substates on wifi and
nvme but skips the Thunderbolt chain, and neither `powersupersave` nor
`link/l1_aspm` moves it. `PLATFORM_PROFILE` has nothing to write to either,
coreboot ships no DYTC.

Worth more than anything TLP does: only `acpi_video0` shows up, no
`intel_backlight`, so brightness has 100 coarse firmware steps and never gets
properly dim, try `acpi_backlight=native`. FBC stays off because of the
compositor's plane format. The touchscreen never suspends, a few hundred mW
that only a udev rule on `04f3:2b23` stops.
