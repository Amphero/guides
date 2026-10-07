# TLP on a coreboot ThinkPad T480

TLP 1.10.2, i7-8550U, coreboot instead of the Lenovo firmware, a Qualcomm
QCNFA765 in place of the stock wifi card, both battery bays filled. Profiles
are switched by hand.

One drop-in, `/etc/tlp.d/01-t480.conf`. Leave `/etc/tlp.conf` empty: it
overrides every drop-in and collects `.pacnew` files. An image-based setup
cannot ship drop-ins from `/usr`, TLP only reads `/etc`, so symlink the
directory from tmpfiles: `L /etc/tlp.d - - - - ../usr/lib/tlp.d`.

## Traps

Since 1.9 the profile picks the suffix, not the power source:
`performance -> *_ON_AC`, `balanced -> *_ON_BAT`, `power-saver -> *_ON_SAV`.
So `TLP_PROFILE_AC=BAL` kills every `*_ON_AC` line in the file, with no error
anywhere. `tlp-stat -m` prints both halves, e.g. `balanced/BAT`.

TLP never resets a parameter the target profile leaves unset. Set
`CPU_MAX_PERF_ON_SAV=60` alone and one trip to power-saver caps the CPU at 60
percent in every profile until reboot. Spell out all three.

Only `CPU_*`, `PCIE_ASPM`, `PLATFORM_PROFILE` and `INTEL_GPU_*` have an
`_ON_SAV`. `WIFI_PWR`, `SOUND_POWER_SAVE`, `RUNTIME_PM`, `DISK_*` and
`MEM_SLEEP` do not, power-saver reuses their `_ON_BAT`.

Commands are `tlp performance | balanced | power-saver`, not `prf`, `bal`,
`sav`. GNOME's power menu switches TLP through `tlp-pd`.

Without `ethtool` installed, `WOL_DISABLE` fails silently.
`ethtool eno0 | grep Wake-on` must read `d`.

## Config

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

`intel_pstate` active only has `powersave` and `performance`; `schedutil` is
rejected on every start and that line only reaches the journal. EPP does the
throttling, so `powersave` plus EPP `performance` gives full turbo at a low
idle draw, while EPP `default` writes `balance_performance` even in a saving
profile. coreboot caps the board at PL1 15 W and PL2 18.75 W, so turbo only
goes in power-saver. Wifi power saving costs 8 ms and triples the jitter on
the QCNFA765 for 0.3-1 W, not worth it.

## Does nothing here

`PCIE_ASPM`: coreboot sets up ASPM on wifi and nvme, L1 plus L1.1/L1.2, and
skips the entire Thunderbolt chain (`00:1d.0`, `02:00.0`, `03:01.0`).
`powersupersave` changes no link, and writing `1` to
`/sys/bus/pci/devices/0000:02:00.0/link/l1_aspm` reads back `0`. Fix it in
coreboot or not at all.

`PLATFORM_PROFILE`: no `platform_profile`, coreboot ships no DYTC.
`INTEL_GPU_POWER_PROFILE`: `xe` driver only, this is i915.
`SATA_LINKPWR`, `AHCI_RUNTIME_PM`, `DISK_APM_LEVEL`: nvme only, APM is ATA.
`NMI_WATCHDOG`, `MEM_SLEEP`: kernel command line.

## Bigger than anything TLP does

Only `acpi_video0` appears, no `intel_backlight`, so brightness has 100 coarse
firmware steps and never gets properly dim. Try `acpi_backlight=native`.

FBC stays off with `pixel format not supported` on plane 1A. That is the
compositor, not a missing module option.

On touch models the touchscreen never suspends, the HID driver blocks it. A
few hundred mW, and only a udev rule on `04f3:2b23` stops it.
