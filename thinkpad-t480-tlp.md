# TLP on a coreboot ThinkPad T480

What this board actually needs, and what looks right but does nothing. TLP
1.10.2, i7-8550U, coreboot instead of the Lenovo firmware, a Qualcomm
QCNFA765 in place of the stock wifi card, both battery bays filled.

Profiles are switched by hand here, never by power source.

## One file

```
/etc/tlp.d/01-t480.conf
```

Leave `/etc/tlp.conf` empty and package managed. It overrides every drop-in,
so a forgotten line there beats the file you are editing, and on Arch it
piles up `.pacnew` files.

Image-based setups cannot ship a drop-in from `/usr`, TLP only reads
`/etc/tlp.conf` and `/etc/tlp.d` (`tlp-readconfs`, line 28). Ship the file as
`/usr/lib/tlp.d/00-t480.conf` and point the directory at it from tmpfiles:

```
L /etc/tlp.d - - - - ../usr/lib/tlp.d
```

`tlp start` applies changes. `tlp-stat -c` shows the effective config with the
file and line every value came from.

## Two traps

Since 1.9 the profile picks the suffix, not the power source:

```
performance -> *_ON_AC    balanced -> *_ON_BAT    power-saver -> *_ON_SAV
```

So `TLP_PROFILE_AC=BAL` makes every `*_ON_AC` line in the file dead, with no
error anywhere. `tlp-stat -m` prints both, e.g. `balanced/BAT`.

TLP does not reset a parameter the target profile leaves unset, the old value
just stays. Set `CPU_MAX_PERF_ON_SAV=60` alone and one trip to power-saver
caps the CPU at 60 percent in every profile until reboot. Spell out all three.

Only `CPU_*`, `PCIE_ASPM`, `PLATFORM_PROFILE` and `INTEL_GPU_*` have an
`_ON_SAV`. `WIFI_PWR`, `SOUND_POWER_SAVE`, `RUNTIME_PM`, `DISK_*` and
`MEM_SLEEP` do not, power-saver reuses their `_ON_BAT` value
(`func.d/25-tlp-func-rf` takes `PP_BAL` and `PP_SAV` in one branch). No hook
exists to get around it.

## The config

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

`intel_pstate` runs active, where the only governors are `powersave` and
`performance`. `schedutil` is rejected on every start with `governor not
available`, and that line only ever reaches the journal.

Keep `powersave` in all three. The `performance` governor pins the top P-state
while idle; on an HWP CPU the throttling happens in EPP below it. Governor
`powersave` with `CPU_ENERGY_PERF_POLICY=performance` gives full turbo under
load at a low idle draw. EPP `default` writes the firmware preference, which
reads back `balance_performance` even in a saving profile.

coreboot caps this board at PL1 15 W and PL2 18.75 W, far under the Lenovo
firmware, so turbo only goes in power-saver:

```bash
cat /sys/class/powercap/intel-rapl:0/constraint_{0,1}_power_limit_uw
```

Both batteries need their own thresholds, `BAT0` internal and `BAT1` the
hot-swap bay. Set only `BAT0` and the other stays wherever the firmware left
it. 75/80 is narrow, good for the cells, a few Wh from the internal pack.

Switching: GNOME's power mode menu works once `tlp-pd` owns the
`net.hadess.PowerProfiles` name and `power-profiles-daemon` is masked.
Otherwise `tlp performance | balanced | power-saver`. Not `prf`, `bal`, `sav`,
those are suffix names, not commands, and TLP exits 3 on them.

## Check it

Run power-saver first so its leftovers show up in the next line:

```bash
for p in power-saver performance balanced; do
  tlp $p >/dev/null
  printf '%-12s %-16s %-20s %s %s\n' "$p" "$(tlp-stat -m)" \
    "$(cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference)" \
    "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" \
    "$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)"
done
```

Expected: EPP `power`/`performance`/`balance_power`, turbo off only in
power-saver, `max_perf_pct` 60/100/100.

The recommendations block at the end of `tlp-stat` should be empty. Without
`ethtool`, `WOL_DISABLE` fails silently because TLP throws the error away;
`ethtool eno0 | grep Wake-on` must read `Wake-on: d`. `smartmontools` is
cosmetic.

## Dead settings

`PCIE_ASPM_ON_*`. coreboot sets up ASPM on wifi and nvme, both with L1 plus
L1.1/L1.2, and skips the whole Thunderbolt chain:

```
00:1c.0 -> wifi   L1 enabled, substates on
00:1d.2 -> nvme   L1 enabled, substates on
00:1d.0 -> TB3    ASPM Disabled, substates off, though LnkCap offers them
02:00.0, 03:01.0  ASPM Disabled
```

`powersupersave` fixes none of it, all eleven links read the same afterwards.
Nor does the per-link file: writing `1` to
`/sys/bus/pci/devices/0000:02:00.0/link/l1_aspm` is accepted and reads back
`0`. No firmware veto in the log, the policy file is writable, the kernel just
refuses that hotplug port. Fix it in coreboot or not at all.

`PLATFORM_PROFILE_ON_*`. No `platform_profile`, no `platform_profile_choices`,
no `dytc_lapmode`, coreboot ships no DYTC. TLP skips it without a word, so a
wrong value sits there looking fine.

`INTEL_GPU_POWER_PROFILE_ON_*` is `xe` only, see `case "$_gpu_driver" in xe)`
in `func.d/45-tlp-func-gpu`. On i915 the knobs are
`INTEL_GPU_MIN/MAX/BOOST_FREQ_ON_*`; leave them, RC6 is on and 300-1150 MHz
are the hardware limits anyway.

`SATA_LINKPWR_ON_*`, `AHCI_RUNTIME_PM_*`, `DISK_APM_LEVEL_*`: no SATA hosts,
nvme only, and APM is an ATA feature. nvme idling is APST in firmware, PCIe
runtime PM reports `unsupported` for this controller.

`NMI_WATCHDOG` and `MEM_SLEEP_ON_*` belong on the kernel command line.

A config written by a GUI leaves tells, like empty `RADEON_DPM_*` and
`AMDGPU_ABM_*` lines on a machine with no AMD graphics.

## Numbers

Package idle from `intel-rapl:0` is around 3.3 W, roughly 1.1 W core and
0.9 W uncore. Desktop idle noise is over a watt, so single samples are a
baseline, not a way to compare profiles.

Wifi power saving on the QCNFA765, ten pings, ms:

| | min | avg | max | mdev |
|---|---|---|---|---|
| off | 22.1 | 24.5 | 31.5 | 2.5 |
| on | 22.8 | 32.6 | 41.2 | 6.2 |

No loss, no `ath11k` errors either way. 0.3-1 W for 8 ms and triple the
jitter. Off here, and off for balanced means off for power-saver too.

## Worth more than any of this

The backlight. Only `acpi_video0` appears, a firmware interface with 100
coarse steps; a T480 on i915 normally also exposes `intel_backlight` with a
raw range and a lower minimum. Try `acpi_backlight=native`.

Framebuffer compression is off:

```
/sys/kernel/debug/dri/1/i915_fbc_status
  FBC disabled: pixel format not supported
  [PLANE:35:plane 1A]: pixel format not supported
```

That is the compositor's plane format, so `i915.enable_fbc=1` does not help.

On touch models the touchscreen sits at `power/control=on` and never
suspends, the HID driver blocks it. A few hundred mW, the largest single item
here, and only a udev rule can stop it:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="04f3", \
  ATTR{idProduct}=="2b23", ATTR{authorized}="0"
```

Not worth it if you use the thing.
