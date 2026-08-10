# Raspberry Pi home server

Two Pi 4 (4 GB). The main one sits in a Geekworm SATA case, boots from a
2 TB SSD and runs Samba, Paperless-ngx and Immich. The second Pi runs
Immich's machine learning. Remote access via Tailscale. Maintenance is one
command a month.

All names and IPs are examples: main server `192.168.0.10`, ML Pi
`192.168.0.11`, users `anna` and `ben`.

---

## 1. Boot from the SATA drive

Once, with an SD card:

1. Write Raspberry Pi OS Lite (64-bit) to the SD with the Raspberry Pi
   Imager. In the imager settings: hostname, SSH on, user + password.
2. After writing, check the boot partition: is there a filled-in
   `user-data`? The Flatpak imager sometimes drops the settings silently.
   If so, create the user and enable SSH by hand, directly on the boot
   partition:
   ```bash
   openssl passwd -6                        # generate a hash
   echo 'anna:<HASH>' > userconf.txt
   touch ssh
   ```
   (Trixie images use cloud-init. To force the first-boot setup to run
   again, change `instance_id` in `meta-data`.)
3. Boot from SD, then:
   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo rpi-eeprom-update -a
   sudo reboot
   ```
4. `sudo raspi-config`, then Advanced Options > Boot Order > USB Boot.

Before trusting the USB-SATA bridge in the case, stress-test it. Cheap
bridges (Innostor IS611) can crash the entire USB bus under load,
including the system drive:

```bash
sudo dd if=/dev/sdX of=/dev/null bs=4M count=512 status=progress   # 2 GB read
sudo dmesg | grep -icE "reset|i/o error"                           # 0 = stable
```

Stopgap for a flaky bridge: USB 2.0 port (~38 MB/s but stable). For
permanent use only chips like ASM1153/JMS578.

Now put the OS on the drive. Either write it fresh with the imager
(cleanest), or clone the running SD system:

```bash
git clone https://github.com/geerlingguy/rpi-clone   # not in apt
sudo cp rpi-clone/rpi-clone /usr/local/sbin/
sudo rpi-clone -U sda
```

If you partition the drive yourself: the Pi 4 bootloader only finds the
FAT32 boot partition at the start of the disk (below ~1 TiB). At the end
it fails, hybrid MBR or not. (The running server splits the SSD into a
540 GB system partition and a 1.3 TB data partition at `/srv/data`; the
imager's default two-partition layout with `/srv` on root works just as
well.)

Remove the SD, reboot, check with `lsblk` that `/` is on `sda2`. What
actually booted, if in doubt:

```bash
od -An -tu4 /proc/device-tree/chosen/bootloader/boot-mode
# 67108864 = USB, 16777216 = SD
```

More stumbling blocks:

- Drive not found at boot (HDD spin-up): `boot_delay=5` in
  `/boot/firmware/config.txt`.
- USB hangs or I/O errors in `dmesg`: UAS quirk. Get the IDs with `lsusb`
  and prepend to the single line in `/boot/firmware/cmdline.txt`:
  `usb-storage.quirks=152d:0578:u`
- USB boot refuses entirely: keep the SD as kernel-only starter, with
  `root=PARTUUID=<drive-partition>` in its `cmdline.txt`.

Keep the SD card in the slot as rescue system.

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

Persistent journal, so logs survive a crash reboot:

```bash
sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald
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

In `/etc/samba/smb.conf`: Debian ships ghost shares that expose every user
home and printer drivers, switch them off in the same edit. Append:

```ini
[global]
   server min protocol = SMB3
   hosts allow = 192.168.0.0/24 100.64.0.0/10 127.0.0.1
   load printers = no

[homes]
   available = no

[printers]
   available = no

[print$]
   available = no

[backup-anna]
   path = /srv/backup/anna
   valid users = anna
   read only = no

[backup-ben]
   path = /srv/backup/ben
   valid users = ben
   read only = no
```

(`100.64.0.0/10` is the Tailscale range. The share name in brackets is
exactly what file managers display.)

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
      # ALLOWED_HOSTS needs every access path (LAN IP, Tailscale IP,
      # hostname), missing ones answer HTTP 400:
      PAPERLESS_ALLOWED_HOSTS: 192.168.0.10,localhost
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

`.env` (set `DB_DATA_LOCATION`, or the database lands in the default
location):

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

Settings that must be right before the first phone upload, because they
are painful to change later:

- Storage template on (admin settings), e.g.
  `{{y}}/{{MM}}/{{dd}}/{{y}}{{MM}}{{dd}}-{{filename}}`. Without it you get
  UUID filenames. Avoid `{{album}}`, files move when albums change.
- Existing photo collections: mount as read-only external library (the
  transformer added the mount), do not import them. The folder structure
  stays authoritative, no lock-in.
- WebP collections: set the preview format to WebP (transparency).
- The OCR job (new in v3) is a CPU hog, turn it off for a pure photo
  archive.

## 7. Second Pi: Immich ML

ML results are stored in the main server's database; the ML container is
stateless. On its own Pi, indexing doesn't fight the services for RAM.

Setup: Raspberry Pi OS Lite (64-bit) on SD, hostname `pi-ml`, SSH on, DHCP
reservation. Repeat step 2 (unattended-upgrades, journal) and step 4
(Docker).

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
(that recomputes everything, "missing" only processes what's new). The
first indexing of a big archive takes days on a Pi. Let it run, it only
happens once, and it happens over there.

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
- MagicDNS on. Android's "Private DNS" overrides it, so names won't
  resolve on the phone: disable "Use Tailscale DNS" in the app and use the
  tailnet IP.

Clients: install the app, same account. Linux desktop tips: KTailctl as
GUI needs `flatpak override --user --filesystem=/run/tailscale
org.fkoehler.KTailctl` and `sudo tailscale set --operator=$USER`. Mounting
SMB through the tunnel wants `vers=3.1.1,sec=ntlmssp` (SMB 3.0 can throw
"Operation not supported").

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

The default policy is allow-all; with the subnet router that means every
tailnet device reaches the whole LAN. Lock it down.

An ACL has `hosts` (alias -> tailnet IP, from the admin console's Machines
list) and `acls` (rules, `src` -> `dst:ports`). The moment you add a rule,
the tailnet flips to deny-by-default, so you list only what should work.
[`files/tailscale-acl.json`](files/tailscale-acl.json) is a template:
laptops get `*:*`, the phone only ports 2283/8000/445 on the main server,
the rest is denied. Swap in your names and IPs (use `groups` if you have
many), paste into Access Controls. Save the old policy first, there is no
undo. Verify from the phone on mobile data: Immich loads, the router page
no longer does.

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
service probes, trash cleanup. No Watchtower, Immich's compose changes
between releases.

### Trash that will not empty

Rename or delete a file of an external library outside Immich and it sets
`deletedAt` on the asset but leaves `status` at `'active'`. The row appears
in the trash, but "empty trash" only touches `status='trashed'` and walks
past it, so those rows survive every attempt and keep reappearing. They can
also crash the mobile sync (`updateAssetFacesV2`). If such an asset is
locked on top of that, the API refuses to hand it out, so it cannot be
deleted that way either.

[`files/immich-trash-cleanup.py`](files/immich-trash-cleanup.py) fixes both:
it sets the rows to `trashed`, unlocks orphans so the API can reach them,
then deletes through the API so thumbnails and database rows go as well.
Nothing is unlocked or deleted unless the file is verifiably gone from disk,
so a locked photo cannot be exposed or lost by accident.

```bash
cp files/immich-trash-cleanup.py ~/ && chmod +x ~/immich-trash-cleanup.py
printf '%s' '<your-api-key>' > ~/.immich_api_key && chmod 600 ~/.immich_api_key
./immich-trash-cleanup.py            # report
./immich-trash-cleanup.py --purge    # clean up
```

`update-server.sh` calls it on every run, so this is handled by the monthly
maintenance.

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
`up -d`. Major upgrades that migrate the DB need a `pg_dump` from before,
pinning doesn't undo a schema migration. Concrete example, Paperless 2 to
3: only works from 2.20.15, needs `PAPERLESS_SECRET_KEY` and
`PAPERLESS_DBENGINE` set, and rebuilds the search index on first start.

## Appendix: migrating existing data

Only relevant when moving data from an old setup.

Verify every copy before deleting the source (empty output = identical):

```bash
sudo rsync -rnc --out-format='DIFF %n' /source/ /target/
```

Large copies onto the system drive: stop the containers first
(`docker compose stop`), that limits the damage if the USB bus flips.

Paperless from an old instance: start the old stack (same Postgres
version!) on a copy of the data, then `document_exporter`, then
`document_importer` into a fresh instance. Users and passwords come along.

Immich duplicate hunting after mixed imports: exact checksums don't catch
format differences (archive WebP vs phone JPG). Czkawka "similar images"
does, with the archive as reference folder. The locked folder is walled
off via API (401); workaround in the DB:
`UPDATE asset SET visibility='timeline' WHERE id IN (...)`, then delete
via API. The table is `asset` (singular), the column `"libraryId"`.
