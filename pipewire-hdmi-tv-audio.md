# Fix HDMI audio on Philips TVs (PipeWire)

Symptom: no or broken sound when a Philips TV hangs on the HDMI output —
the TV can't handle the format PipeWire negotiates. Fix: pin the ALSA node
to plain 16-bit stereo via a WirePlumber rule.

Find your node name first (`wpctl status`), then adjust the `node.name`
match below.

```bash
mkdir -p ~/.config/wireplumber/wireplumber.conf.d/
```

`~/.config/wireplumber/wireplumber.conf.d/99-hdmi-format-fix.conf`:

```
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.pci-0000_00_1f.3.hdmi-stereo"
      }
    ]
    actions = {
      update-props = {
        audio.format = "S16LE"
        audio.channels = 2
        audio.position = "FL,FR"
      }
    }
  }
]
```

```bash
systemctl --user restart pipewire.service wireplumber.service
```
