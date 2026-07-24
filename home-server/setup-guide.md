# Raspberry Pi home server

Two Pi 4 (4 GB). The main one sits in a Geekworm SATA case, boots from a
2 TB SSD and runs Samba, Paperless-ngx and Immich. The second Pi runs
Immich's machine learning. Remote access via Tailscale. Maintenance is one
command a month.

All names and IPs are examples: main server `192.168.0.10`, ML Pi
`192.168.0.11`, users `anna` and `ben`. Final state:
[current-setup.md](current-setup.md).

1. [Boot from the SATA drive](#1-boot-from-the-sata-drive)
2. [Base setup](#2-base-setup)
3. [Samba](#3-samba)
4. [Docker](#4-docker)
5. [Paperless-ngx](#5-paperless-ngx)
6. [Immich](#6-immich)
7. [Second Pi: Immich ML](#7-second-pi-immich-ml)
8. [Tailscale](#8-tailscale)
9. [Maintenance](#9-maintenance)
10. [Lessons learned](#lessons-learned)

---

## 1. Boot from the SATA drive

Once, with an SD card:

1. Write Raspberry Pi OS Lite (64-bit) to the SD with the Raspberry Pi
   Imager. In the imager settings: hostname, SSH on, user + password.
   After writing, check the boot partition for a filled-in `user-data`.
   The Flatpak imager sometimes drops the settings
   ([Lessons learned](#imager--first-boot)).
2. Boot from SD, then:
   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo rpi-eeprom-update -a
   sudo reboot
   ```
3. `sudo raspi-config`, then Advanced Options > Boot Order > USB Boot.

Then put the OS on the SATA drive. Either write it fresh with the imager
(cleanest), or clone the running SD system:

```bash
git clone https://github.com/geerlingguy/rpi-clone   # not in apt
sudo cp rpi-clone/rpi-clone /usr/local/sbin/
sudo rpi-clone -U sda
```

Remove the SD, reboot, check with `lsblk` that `/` is on `sda2`. Keep the
SD card as rescue system.

Troubleshooting:

- Drive not found at boot: `boot_delay=5` in `/boot/firmware/config.txt`.
- USB hangs or I/O errors in `dmesg`: UAS quirk
  ([Lessons learned](#booting-from-large-drives-pi-4)).
- Before big copy jobs, stress-test the USB-SATA bridge. Cheap ones crash
  the whole bus ([Lessons learned](#usb-sata-bridges-most-expensive-lesson)).

## 2. Base setup

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install unattended-upgrades -y
sudo dpkg-reconfigure -plow unattended-upgrades   # answer Yes
```

Auto-reboot on kernel updates, in `/etc/apt/apt.conf.d/50unattended-upgrades`:

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

Fixed IP: DHCP reservation in the router, nothing on the Pi.

```bash
sudo mkdir -p /srv/backup/anna /srv/backup/ben
sudo mkdir -p /srv/docker/paperless /srv/docker/immich
```

## 3. Samba

Samba users must exist as Linux users. Nologin without home is enough:

```bash
sudo apt install samba -y
sudo adduser --system --no-create-home --shell /usr/sbin/nologin --group anna
sudo adduser --system --no-create-home --shell /usr/sbin/nologin --group ben
sudo smbpasswd -a anna
sudo smbpasswd -a ben
sudo chown anna:anna /srv/backup/anna
sudo chown ben:ben  /srv/backup/ben
sudo chmod 700 /srv/backup/anna /srv/backup/ben
```

Append to `/etc/samba/smb.conf` (`100.64.0.0/10` is Tailscale):

```ini
[global]
   server min protocol = SMB3
   hosts allow = 192.168.0.0/24 100.64.0.0/10 127.0.0.1

[backup-anna]
   path = /srv/backup/anna
   valid users = anna
   read only = no

[backup-ben]
   path = /srv/backup/ben
   valid users = ben
   read only = no
```

Disable Debian's ghost shares while you're in there
([Lessons learned](#samba-1)).

```bash
testparm
sudo systemctl restart smbd
```

Access: `smb://192.168.0.10/backup-anna`, login `anna` + Samba password.

## 4. Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER    # re-login afterwards
```

Log rotation, or container logs grow forever. `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

Memory cgroups are off by default (`docker stats` shows 0B). Append to the
single line in `/boot/firmware/cmdline.txt`:

```
cgroup_enable=memory cgroup_memory=1
```

Reboot.

## 5. Paperless-ngx

`/srv/docker/paperless/docker-compose.yml`:

```yaml
services:
  broker:
    image: docker.io/library/redis:7
    restart: unless-stopped
    volumes:
      - redisdata:/data

  db:
    image: docker.io/library/postgres:16
    restart: unless-stopped
    volumes:
      - pgdata:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: paperless
      POSTGRES_USER: paperless
      POSTGRES_PASSWORD: paperless   # change

  webserver:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    restart: unless-stopped
    depends_on:
      - db
      - broker
    ports:
      - "8000:8000"
    volumes:
      - ./data:/usr/src/paperless/data
      - ./media:/usr/src/paperless/media
      - ./export:/usr/src/paperless/export
      - ./consume:/usr/src/paperless/consume
    environment:
      PAPERLESS_REDIS: redis://broker:6379
      PAPERLESS_DBENGINE: postgresql        # required since v3
      PAPERLESS_DBHOST: db
      PAPERLESS_DBPASS: paperless           # same as above
      PAPERLESS_TIME_ZONE: Europe/Berlin
      PAPERLESS_OCR_LANGUAGE: deu
      PAPERLESS_URL: http://192.168.0.10:8000
      PAPERLESS_ALLOWED_HOSTS: 192.168.0.10,localhost   # add Tailscale IP later, or HTTP 400
      PAPERLESS_SECRET_KEY: change-me       # openssl rand -base64 48
      PAPERLESS_THREADS_PER_WORKER: 2       # 4 GB Pi: leave cores for the rest
      PAPERLESS_CONVERT_MEMORY_LIMIT: 64    # cap ImageMagick on big scans
      PAPERLESS_CONSUMER_DELETE_DUPLICATES: "true"  # v3 keeps duplicates by default

volumes:
  pgdata:
  redisdata:
```

```bash
docker compose up -d
docker compose run --rm webserver createsuperuser   # run --rm, not exec
```

Files dropped into `consume/` get ingested automatically.

## 6. Immich

Immich's compose file changes between releases. Always work from the
upstream file:

```bash
cd /srv/docker/immich
wget -O docker-compose.yml.upstream https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env
```

`.env`:

```
UPLOAD_LOCATION=/srv/docker/immich/library
DB_DATA_LOCATION=/srv/docker/immich/postgres
DB_PASSWORD=change-me
TZ=Europe/Berlin
```

Local compose changes (drop the ML service, add the external library,
cap Postgres RAM) live in [`files/transform-compose.py`](files/transform-compose.py),
so they survive updates. Copy it to `/srv/docker/immich/`, adjust the
constants at the top, then:

```bash
python3 transform-compose.py docker-compose.yml.upstream docker-compose.yml
docker compose up -d
```

Single-Pi setup: see the note in the script.

Before the first phone upload: storage template on, existing photos as
read-only external library ([Lessons learned](#immich-1)).

## 7. Second Pi: Immich ML

ML results are stored in the main server's database; the ML container is
stateless. On its own Pi, indexing doesn't fight the services for RAM.

Setup: Raspberry Pi OS Lite (64-bit) on SD, hostname `pi-ml`, SSH on, DHCP
reservation. Repeat step 2 (unattended-upgrades) and step 4 (Docker).

```bash
sudo mkdir -p /srv/docker/immich-ml && sudo chown $USER: /srv/docker/immich-ml
```

Copy [`files/immich-ml-compose.yml`](files/immich-ml-compose.yml) there as
`docker-compose.yml`. The image tag must match the server's major version.
The preload variable keeps the CLIP text model in RAM; without it the first
search after idle waits 15-45 s.

```bash
docker compose up -d
curl http://localhost:3003/ping    # pong
```

In the Immich admin settings under Machine Learning, set the URL to
`http://192.168.0.11:3003`. Then run the missing jobs once, never "all"
(that recomputes everything).

### Update path from the main server

The maintenance script (step 9) updates the ML Pi over SSH with a key that
can only run one command.

On the ML Pi, install [`files/ml-update.sh`](files/ml-update.sh):

```bash
sudo install -o root -g root -m 755 ml-update.sh /usr/local/bin/ml-update.sh
echo 'pi-admin ALL=(root) NOPASSWD: /usr/local/bin/ml-update.sh' | sudo tee /etc/sudoers.d/ml-update
sudo chmod 440 /etc/sudoers.d/ml-update
sudo visudo -c
```

On the main server:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_mlpi_update -C 'main-to-mlpi-update'
cat ~/.ssh/id_mlpi_update.pub
```

Back on the ML Pi, add it to `~/.ssh/authorized_keys` with a forced
command (no shell, no forwarding):

```
restrict,command="sudo /usr/local/bin/ml-update.sh" ssh-ed25519 AAAA... main-to-mlpi-update
```

Test from the main server. This must run the update script and nothing
else:

```bash
ssh -i ~/.ssh/id_mlpi_update pi-admin@192.168.0.11 'cat /etc/passwd'
```

## 8. Tailscale

DS-Lite means no port forwarding; Tailscale connects from the inside out,
so CGNAT doesn't matter.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up      # prints a login URL
```

Admin console:

- Disable key expiry, but only for the server. Clients re-auth in seconds;
  expiry is what removes a lost phone automatically.
- MagicDNS on. Android's "Private DNS" overrides it, use the tailnet IP
  there.

Clients: install the app, same account.

### Subnet router

Makes the Pi's LAN IP work from anywhere, so every app keeps one server
address:

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
sudo tailscale up --advertise-routes=192.168.0.0/24
```

Approve the route in the admin console; enable "Use subnet routes" on the
clients. Add the Pi's tailnet IP to `PAPERLESS_ALLOWED_HOSTS`.

### ACL and device approval

The default policy is allow-all. With the subnet router, any tailnet
device reaches the whole LAN.
[`files/tailscale-acl.json`](files/tailscale-acl.json) restricts the phone
to the three services; laptops keep full access. Adjust the IPs, paste
into Access Controls. Copy the old policy somewhere first, there is no
undo. Verify from the phone on mobile data: Immich works, the router page
doesn't load anymore.

Under Settings > Device management, enable "Manually approve new devices".

Put MFA (best: a passkey) on the account behind the tailnet. That account
owns your LAN.

## 9. Maintenance

Copy [`files/update-server.sh`](files/update-server.sh) to
`~/update-server.sh` on the main server, adjust the variables at the top,
`chmod +x`, `sudo apt install smartmontools`. Monthly, after a glance at
the Immich release notes:

```bash
ssh -t <user>@192.168.0.10 ./update-server.sh
```

One run: apt on both Pis, SMART check, Paperless, Immich (upstream compose
fetched and rebuilt, new `.env` variables listed), ML Pi, image prune,
service probes. No Watchtower, Immich's compose changes between releases.

Backups: Immich dumps its DB nightly to `UPLOAD_LOCATION/backups/`; get
documents and photos off the machine regularly (backup tool to an external
drive, or rsync).

Manual fallback:

```bash
# backup first:
cd /srv/docker/paperless && docker compose exec webserver document_exporter ../export
# then per service: pull + up -d; Immich via transform-compose.py as in step 6
```

Rollback: pin the previous image tag (`IMMICH_VERSION` in `.env`),
`up -d`. Major upgrades that migrate the DB (Paperless 2 to 3) need a
`pg_dump` from before, pinning doesn't undo a schema migration.

---

## Lessons learned

### Imager & first boot

- The Flatpak imager can silently drop SSH/user/hostname settings. Check
  for a filled `user-data` on the boot partition. Fallback, directly on
  bootfs:
  ```bash
  openssl passwd -6
  echo 'anna:<HASH>' > userconf.txt
  touch ssh
  ```
- Trixie images use cloud-init: change `instance_id` in `meta-data` to
  force first-boot setup to run again.

### Booting from large drives (Pi 4)

- The bootloader only boots GPT disks whose FAT32 boot partition sits at
  the start of the disk (below ~1 TiB). At the end it fails, hybrid MBR
  or not.
- Fallback when USB boot refuses: SD card carries only the kernel,
  `root=PARTUUID=<drive>` in its `cmdline.txt`.
- What actually booted:
  `od -An -tu4 /proc/device-tree/chosen/bootloader/boot-mode`
  (67108864 = USB, 16777216 = SD).

### USB-SATA bridges (most expensive lesson)

- Cheap bridges (Innostor IS611) can crash the entire USB bus under load,
  including the system drive. Endless resets in `dmesg`. Test first:
  ```bash
  sudo dd if=/dev/sdX of=/dev/null bs=4M count=512 status=progress
  sudo dmesg | grep -icE "reset|i/o error"   # 0 = stable
  ```
- Stopgap: USB 2.0 port (~38 MB/s but stable). For permanent use:
  ASM1153/JMS578.
- Stop containers before large copies onto the system drive.

### Migration safety

- Persistent journal before anything risky, or crash logs vanish on
  reboot:
  ```bash
  sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald
  ```
- Verify copies before destructive steps (empty output = identical):
  ```bash
  sudo rsync -rnc --out-format='DIFF %n' /source/ /target/
  ```

### Samba

- Debian ships ghost shares: `available = no` under
  `[homes]`/`[printers]`/`[print$]`, `load printers = no` in `[global]`.

### Paperless-ngx

- `PAPERLESS_ALLOWED_HOSTS` needs every access path (LAN IP, tailnet IP,
  hostname), or HTTP 400.
- Superuser: `run --rm`, not `exec`.
- Migrating an instance: old stack (same Postgres version!) on a copy of
  the data, `document_exporter`, then `document_importer` into a fresh
  instance. Users and passwords come along.
- The 2 to 3 upgrade: only from 2.20.15, needs `PAPERLESS_SECRET_KEY` and
  `PAPERLESS_DBENGINE`, rebuilds the search index on first start.
  `pg_dump` first, the migration is one-way.

### Immich

- Existing collections: read-only external library, not import.
- Storage template before the first upload (e.g.
  `{{y}}/{{MM}}/{{dd}}/{{y}}{{MM}}{{dd}}-{{filename}}`), or you get UUID
  filenames. Avoid `{{album}}`, files move when albums change.
- ML results live in the main DB, the ML container can be moved or
  rebuilt freely. After changes run "missing" jobs, never "all".
- First indexing of a big archive takes days on a Pi. Once.
- WebP collections: preview format WebP. The v3 OCR job is a CPU hog,
  turn it off for a photo archive.
- Duplicates across formats (WebP vs JPG) escape checksums. Czkawka
  "similar images" finds them, archive as reference folder. The locked
  folder is fully walled off via API (401); DB workaround:
  `UPDATE asset SET visibility='timeline' WHERE id IN (...)`, then delete
  via API. Table `asset` (singular), column `"libraryId"`.

### Tailscale

- Android "Private DNS" kills MagicDNS names, use the tailnet IP.
- Key expiry off only for the server.
- KTailctl (Flatpak):
  `flatpak override --user --filesystem=/run/tailscale org.fkoehler.KTailctl`
  plus `sudo tailscale set --operator=$USER`.
- SMB through the tunnel: `vers=3.1.1,sec=ntlmssp`.
- The ACL editor validates on save but has no undo, copy the old policy
  first.
