# What the finished system looks like

State of the real build (July 2026), with example names and IPs. How to get
here: [setup-guide.md](setup-guide.md).

## Hardware & boot

- Main server: Raspberry Pi 4 (4 GB) in a Geekworm SATA case, 2 TB SSD in
  the bay. Boots straight from the SSD (GPT; boot order `0xf14` = USB
  first). An SD card sits in the slot as rescue system: a standalone
  bootable OS that only kicks in if the SSD doesn't boot.
- ML server: second Pi 4 (4 GB), `pi-ml`, runs from a 32 GB SD card. Only
  Docker plus the Immich ML container.

## SSD partition layout (GPT), main server

| Partition | Size | Content |
|---|---|---|
| `sda1` bootfs (FAT32, at the disk start!) | 512 MB | bootloader + kernel = `/boot/firmware` |
| `sda2` rootfs (ext4) | 540 GB | system, Docker, Paperless & Immich data |
| `sda5` data (ext4) | 1.3 TB | user data, mounted at `/srv/data` (fstab, `nofail`) |

## Services & paths

- Samba (main server): `[backup-anna]` = `/srv/backup/anna`,
  `[backup-ben]` = `/srv/backup/ben`; nologin system users; `[homes]`,
  `[printers]`, `[print$]` disabled.
- Paperless-ngx (`/srv/docker/paperless`, port 8000): v3, RAM tuning in
  the compose file (`THREADS_PER_WORKER: 2`, `CONVERT_MEMORY_LIMIT: 64`,
  `CONSUMER_DELETE_DUPLICATES: "true"` = pre-v3 duplicate behavior).
- Immich (`/srv/docker/immich`, port 2283): phone uploads with storage
  template `{{y}}/{{MM}}/{{dd}}/{{y}}{{MM}}{{dd}}-{{filename}}`; photo
  archive mounted as read-only external library; preview format WebP;
  Postgres capped at `shared_buffers=256MB`. The compose file is generated
  by `transform-compose.py` from the upstream template. Local changes
  belong in that script, never in the compose file itself.
- Immich ML (`pi-ml:3003`, `/srv/docker/immich-ml`): CLIP text model
  preloaded permanently (search answers instantly), other models unload
  after 1 h idle. ML URL set in the Immich admin settings. Version pinned
  to the same major tag as the server.
- Updates: unattended-upgrades on both Pis (auto-reboot 04:00);
  everything else via `~/update-server.sh` on the main server, one command
  a month. It updates both Pis, all containers, rebuilds the Immich
  compose, checks SMART, probes all services. The ML Pi is reached through
  a dedicated SSH key locked to a single forced command (`ml-update.sh`),
  backed by a sudoers exception for exactly that script.
- Docker log rotation (10 MB x 3) and memory cgroups active on both Pis.
- Persistent journal on both Pis.

## Access (the one address)

- The main server's LAN IP works everywhere: at home directly (DHCP
  reservation in the router), on the road through Tailscale. The Pi is a
  subnet router for `192.168.0.0/24` (route approved in the admin console;
  no exit node).
- Services: `http://192.168.0.10:2283` (Immich), `:8000` (Paperless;
  `PAPERLESS_ALLOWED_HOSTS` contains LAN and tailnet IP), `smb://...`.
- MagicDNS unused on Android (private DNS wins), access is by IP.

## Security

- SSH: password login only (no stored keys), sudo requires a password.
  The single permanent exception is the restricted main-to-ML key
  described above, which cannot open a shell.
- Tailscale: least-privilege ACL (laptops full access, phone only reaches
  the three services on the main server), device approval on, key expiry
  disabled only for the server.

## Backups

- The Samba shares are backups of other machines. The server's own data
  (documents, photos) additionally leaves the machine via a backup tool to
  an external drive.
- Immich writes nightly DB dumps to `UPLOAD_LOCATION/backups/` (kept: 14).
- Cold backup of all irreplaceable data on a shelved external drive,
  checksum-verified, refreshed manually on purpose.
