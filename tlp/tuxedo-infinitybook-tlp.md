# TLP on a TUXEDO InfinityBook 14 v5

i5-10210U, Intel AX200 wifi, Realtek RTL8111 Ethernet with RTL8411B card
reader, Samsung 970 EVO Plus NVMe, Thunderbolt 3. Profiles are switched by
hand, GNOME's power menu drives TLP through tlp-pd.

```bash
pacman -R power-profiles-daemon
pacman -S tlp tlp-pd ethtool
systemctl mask power-profiles-daemon systemd-rfkill.service systemd-rfkill.socket
systemctl enable --now tlp tlp-pd
```

tlp-pd replaces power-profiles-daemon. With `--noconfirm` pacman refuses the
swap and installs nothing, so remove it first.

Settings go in `/etc/tlp.d/01-infinitybook.conf`, see the
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
```

`_ON_AC` is performance, `_ON_BAT` balanced, `_ON_SAV` power-saver. Switch
from the GNOME menu or with `tlp performance | balanced | power-saver`, check
with `tlp-stat -m`.

`intel_pstate` already runs active with `powersave`, driver and governor need
no setting.

Without TLP only the Ethernet controller and the wifi card sit at `on`, the
other PCI devices and all USB devices are already at `auto`. TLP's defaults
put those two at `auto` as well in balanced and power-saver.

No platform profile. Wifi power saving is on by default.

No charge thresholds, the battery exposes none without the TUXEDO drivers.
