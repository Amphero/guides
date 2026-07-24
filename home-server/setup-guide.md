# Raspberry Pi home server: SATA boot, Samba, Paperless-ngx, Immich + a second Pi for ML

Goal: a low-maintenance server that boots from a SATA drive, offers two
password-protected Samba shares (backup targets), runs Paperless-ngx and
Immich in Docker, offloads Immich's machine learning to a second Pi, and is
reachable from anywhere via Tailscale. Monthly maintenance is one command.

Hardware: two Raspberry Pi 4 (4 GB). The main one sits in a Geekworm SATA
case (the drive connects internally through a USB-SATA bridge, e.g.
X825/X862/NASPi series). The second Pi runs plain from an SD card.

> All names, IPs and passwords in this guide are **examples**
> (main server `192.168.0.10`, ML Pi `192.168.0.11`, users `anna`/`ben`).
> What the finished system looks like is in [current-setup.md](current-setup.md).
> Expensive pitfalls are collected in "Lessons learned" at the end — the ⚠️
> markers in the phases point there.

---

## Phase 1: Boot from the SATA drive

### 1.1 Update the bootloader (once, with an SD card)

1. Write Raspberry Pi OS Lite (64-bit) to an SD card with the **Raspberry Pi
   Imager**. In the imager settings (gear icon) configure hostname, enable
   SSH, username + password, WLAN if needed.
   ⚠️ **After writing, check that your settings actually made it onto the
   card** (boot partition: is `user-data` filled in?) — the Flatpak imager
   sometimes drops them silently. Fallback: see "Lessons learned → Imager".
2. Boot from the SD card, connect via SSH, update:
   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo rpi-eeprom-update -a
   sudo reboot
   ```
3. Set the boot order to "USB first":
   ```bash
   sudo raspi-config
   ```
   → *Advanced Options* → *Boot Order* → **USB Boot**. Internally this sets
   `BOOT_ORDER=0xf14` (try USB, then SD).

### 1.2 Get the system onto the SATA drive

Two ways — **A is the cleanest**:

**A (fresh install):** Connect the drive to a PC via USB adapter (or to the
Pi itself) and write Raspberry Pi OS Lite (64-bit) onto it with the imager —
same settings as before (SSH, user). Remove the SD card, reboot.

**B (clone the SD system):** On the running Pi (rpi-clone is **not** in apt,
only on GitHub):
```bash
git clone https://github.com/geerlingguy/rpi-clone
sudo cp rpi-clone/rpi-clone /usr/local/sbin/
sudo rpi-clone -U sda        # -U = unattended incl. initialization
```
Shut down, remove the SD card, reboot.

### 1.3 Verify, and typical stumbling blocks

- Check that the system really booted from the drive:
  ```bash
  lsblk        # root (/) should be on sda2
  ```
- **HDD spin-up:** a mechanical drive needs a few seconds. If the Pi misses
  it at boot, add to `/boot/firmware/config.txt`:
  ```
  boot_delay=5
  ```
- **UAS trouble:** some USB-SATA chips (often JMicron in Geekworm boards)
  misbehave with the UAS driver (hangs, I/O errors in `dmesg`). If so, find
  the vendor/product ID with `lsusb` and prepend to
  `/boot/firmware/cmdline.txt` (everything stays on one line):
  ```
  usb-storage.quirks=152d:0578:u
  ```
- ⚠️ **Stress-test the USB-SATA bridge before large copy jobs** (cheap chips
  can take down the whole USB bus, including the system drive): see
  "Lessons learned → USB-SATA bridges".
- ⚠️ **Large drives/GPT:** the Pi 4 bootloader only finds the FAT boot
  partition at the **start of the disk** (below ~1 TiB): see
  "Lessons learned → Booting from large drives".
- Keep the SD card in a drawer — it is your rescue system.

---

## Phase 2: Base setup (low-maintenance)

```bash
sudo apt update && sudo apt full-upgrade -y
```

### 2.1 Fixed IP address

Easiest: a **DHCP reservation** for the Pi in your router (e.g.
192.168.0.10). Less to maintain than static configuration on the Pi, and
nothing to change on the Pi itself.

### 2.2 Automatic security updates

```bash
sudo apt install unattended-upgrades -y
sudo dpkg-reconfigure -plow unattended-upgrades   # → Yes
```

Optionally allow automatic reboots on kernel updates in
`/etc/apt/apt.conf.d/50unattended-upgrades`:
```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

### 2.3 Data directories

Everything important in one place — makes backups and orientation easy:

```bash
sudo mkdir -p /srv/backup/anna /srv/backup/ben   # adjust names
sudo mkdir -p /srv/docker/paperless /srv/docker/immich
```

---

## Phase 3: Samba with two users

### Do I need two Linux users?

**Short answer: yes, but only as shells of users.** Samba (with the default
password backend) requires every Samba user to exist as a Linux user. These
users need **no login, no shell, no home directory** — they only exist so
Samba can attach a password and file ownership to them. You keep
administering everything through your one main user over SSH.

The alternative (one shared Samba account for both people) works, but then
both share a password and see each other's backups. Two separate accounts
are two more commands and considerably cleaner.

### 3.1 Install and create users

```bash
sudo apt install samba -y

# Login-less system users (no home, no shell):
sudo adduser --system --no-create-home --shell /usr/sbin/nologin --group anna
sudo adduser --system --no-create-home --shell /usr/sbin/nologin --group ben

# Set Samba passwords (these are the network access passwords):
sudo smbpasswd -a anna
sudo smbpasswd -a ben
```

### 3.2 Permissions on the backup folders

```bash
sudo chown anna:anna /srv/backup/anna
sudo chown ben:ben  /srv/backup/ben
sudo chmod 700 /srv/backup/anna /srv/backup/ben
```

### 3.3 Configure the shares

Append to `/etc/samba/smb.conf`:

```ini
[global]
   server min protocol = SMB3
   # access only from LAN + the Tailscale range:
   hosts allow = 192.168.0.0/24 100.64.0.0/10 127.0.0.1

[backup-anna]
   path = /srv/backup/anna
   valid users = anna
   read only = no
   browseable = yes

[backup-ben]
   path = /srv/backup/ben
   valid users = ben
   read only = no
   browseable = yes
```

(Adjust `192.168.0.0/24` to your network; `100.64.0.0/10` is the range
Tailscale will use later.)

```bash
testparm            # check the configuration
sudo systemctl restart smbd
```

💡 Debian ships ghost shares (`[homes]` exposes user homes, `print$` printer
drivers) — disable them: see "Lessons learned → Samba".

Access from a PC: `\\192.168.0.10\backup-anna` (Windows) or
`smb://192.168.0.10/backup-anna` (macOS/Linux), log in as `anna` with the
Samba password.

---

## Phase 4: Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
# log out and back in, then test:
docker run --rm hello-world
```

Docker Compose comes with it as a plugin (`docker compose version`).

### 4.1 Log rotation (do this right away)

Without it, container logs grow **unbounded**. Create
`/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

### 4.2 Memory cgroups

Raspberry Pi OS ships with the memory cgroup disabled — `docker stats` shows
"0B / 0B" and memory limits don't work. Enable it by appending to the single
line in `/boot/firmware/cmdline.txt`:

```
cgroup_enable=memory cgroup_memory=1
```

Then reboot (this also activates the log rotation from 4.1).

---

## Phase 5: Paperless-ngx

```bash
cd /srv/docker/paperless
```

Create `docker-compose.yml`:

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
      POSTGRES_PASSWORD: paperless   # change this!

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
      PAPERLESS_DBENGINE: postgresql   # required since v3
      PAPERLESS_DBHOST: db
      PAPERLESS_DBPASS: paperless      # same as above
      PAPERLESS_TIME_ZONE: Europe/Berlin
      PAPERLESS_OCR_LANGUAGE: deu
      PAPERLESS_URL: http://192.168.0.10:8000
      PAPERLESS_ALLOWED_HOSTS: 192.168.0.10,localhost   # + Tailscale IP later, or you get HTTP 400!
      PAPERLESS_SECRET_KEY: put-a-long-random-string-here   # generate: openssl rand -base64 48
      # Tuning for a 4 GB Pi:
      PAPERLESS_THREADS_PER_WORKER: 2       # OCR leaves cores for the rest of the system
      PAPERLESS_CONVERT_MEMORY_LIMIT: 64    # caps ImageMagick RAM on large scans
      PAPERLESS_CONSUMER_DELETE_DUPLICATES: "true"  # v3 default keeps duplicates; this restores the old behavior

volumes:
  pgdata:
  redisdata:
```

Start it and create the admin account:

```bash
docker compose up -d
docker compose run --rm webserver createsuperuser   # run --rm, not exec!
```

Open `http://192.168.0.10:8000`. Documents dropped into
`/srv/docker/paperless/consume` are ingested automatically — you can expose
that folder via Samba as a scanner target if you like.

---

## Phase 6: Immich

Immich publishes an official compose file that changes between releases, so
always fetch the originals:

```bash
cd /srv/docker/immich
wget -O docker-compose.yml.upstream https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env
```

In `.env`, adjust at least:

```
UPLOAD_LOCATION=/srv/docker/immich/library
DB_DATA_LOCATION=/srv/docker/immich/postgres    # otherwise the DB lands in the default location!
DB_PASSWORD=a-secure-password
TZ=Europe/Berlin
```

Local changes to the compose file (removing the ML service because it runs
on the second Pi, adding the external library mount, capping Postgres RAM)
are done by a small script instead of by hand — that way they survive every
update. Copy [`files/transform-compose.py`](files/transform-compose.py) to
`/srv/docker/immich/`, adjust the constants at the top, then:

```bash
python3 transform-compose.py docker-compose.yml.upstream docker-compose.yml
docker compose up -d
```

(Running everything on a single Pi? See the note at the top of the script.)

Open `http://192.168.0.10:2283`, create the admin account, connect the phone
app to this address.

💡 Before the first phone upload: enable the **storage template** and mount
existing photo collections as a **read-only external library** instead of
importing them — see "Lessons learned → Immich".

---

## Phase 7: The second Pi as Immich ML server

Immich's machine learning (smart search, face recognition) is the heaviest
part of the whole stack. On a single 4 GB Pi it fights with everything else
for RAM — on its own Pi it has all 4 GB to itself, and the main server never
notices indexing runs. The ML container is stateless (all results land in
the main server's database), so this split is cheap.

### 7.1 Set up the Pi

Raspberry Pi OS Lite (64-bit) on an SD card (fine here — the model cache is
1–2 GB and rarely written), hostname `pi-ml`, SSH enabled, DHCP reservation
(e.g. 192.168.0.11). Then repeat the basics: unattended-upgrades (2.2),
Docker incl. log rotation and cgroups (4.x).

### 7.2 ML container

```bash
sudo mkdir -p /srv/docker/immich-ml && sudo chown $USER: /srv/docker/immich-ml
cd /srv/docker/immich-ml
```

Copy [`files/immich-ml-compose.yml`](files/immich-ml-compose.yml) here as
`docker-compose.yml`. Pin the image tag to the same major version as the
server (`v3` if the main server uses `IMMICH_VERSION=v3`). The environment
block preloads the CLIP text model permanently — search then answers
instantly instead of after a 15–45 s model load. Start:

```bash
docker compose up -d
curl http://localhost:3003/ping    # → "pong"
```

Models download automatically on first use. (Migrating from ML on the main
server? Copy the model cache over instead:
`docker cp immich_machine_learning:/cache - | ssh pi-ml 'tar -xf - ...'` —
and don't worry about the already-computed results, they live in the main
database and survive the move.)

### 7.3 Point Immich at it

Immich admin UI → Administration → Settings → Machine Learning: set the URL
to `http://192.168.0.11:3003`, make sure ML is enabled. Then run the
"missing" jobs (not "all"!) once — only new photos get processed, existing
results are kept.

### 7.4 Update path from the main server (restricted key)

So the monthly maintenance script can update the ML Pi too, the main server
gets an SSH key that can do **exactly one thing** there.

On the ML Pi, install [`files/ml-update.sh`](files/ml-update.sh) as root and
allow it — and only it — via sudo without password:

```bash
sudo install -o root -g root -m 755 ml-update.sh /usr/local/bin/ml-update.sh
echo 'pi-admin ALL=(root) NOPASSWD: /usr/local/bin/ml-update.sh' | sudo tee /etc/sudoers.d/ml-update
sudo chmod 440 /etc/sudoers.d/ml-update
sudo visudo -c    # must report "parsed OK"
```

On the main server, create a dedicated key and note the public key:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_mlpi_update -C 'main-to-mlpi-update'
cat ~/.ssh/id_mlpi_update.pub
```

Back on the ML Pi, add it to `~/.ssh/authorized_keys` — with a forced
command, so this key can never open a shell, forward ports or run anything
else:

```
restrict,command="sudo /usr/local/bin/ml-update.sh" ssh-ed25519 AAAA... main-to-mlpi-update
```

Test from the main server — even asking for a shell must only run the
update:

```bash
ssh -i ~/.ssh/id_mlpi_update pi-admin@192.168.0.11 'cat /etc/passwd'
# → runs ml-update.sh, nothing else
```

---

## Phase 8: Remote access with Tailscale

With DS-Lite cable internet (no public IPv4) classic port forwarding is
dead. **Tailscale** solves this elegantly: WireGuard under the hood, but
connections are built from the inside out, which walks through CGNAT
automatically. No port forwarding, no DynDNS, no router changes. The free
plan (3 users, 100 devices) is plenty.

### 8.1 Install on the Pi

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

The command prints a URL — open it, log in (Google/GitHub/Microsoft/email).
The Pi is now in your tailnet with a stable IP (`100.x.x.x`).

In the **admin console** (https://login.tailscale.com/admin):

1. Set **"Disable key expiry" — but only for the server.** Phones and
   laptops re-authenticate in ten seconds every 180 days; a stolen one drops
   out of the tailnet automatically. The server is the one device where an
   expired key means a silent outage.
2. **MagicDNS** (under *DNS*, usually already on) — reach the Pi by name.
   ⚠️ Android's "Private DNS" overrides MagicDNS — just use the stable
   tailnet IP there: see "Lessons learned → Tailscale".

### 8.2 Clients

Install the Tailscale app on every device, log in with the same account.
For the second person: either enroll their devices under your account
(simplest) or invite them as a separate user.

### 8.3 Subnet router: one address that works everywhere

Making the Pi a subnet router means its **LAN IP works from anywhere** —
at home directly, on the road through the tunnel. Apps keep one server
address, always.

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

sudo tailscale up --advertise-routes=192.168.0.0/24
```

Then **approve the route** in the admin console (device → *Edit route
settings*), and enable "Use subnet routes" on the clients. By default only
home-network traffic goes through the Pi (split tunnel); normal browsing
stays direct.

Add the tailnet IP of the Pi to `PAPERLESS_ALLOWED_HOSTS`, or Paperless
answers HTTP 400 through the tunnel.

### 8.4 Lock it down: ACL and device approval

The default tailnet policy is **allow all** — combined with the subnet
router, every tailnet device reaches your entire LAN, router admin page
included. The realistic risk at home is a lost or compromised phone. Two
cheap fixes:

1. **Least-privilege ACL:** [`files/tailscale-acl.json`](files/tailscale-acl.json)
   — laptops keep full access, the phone only reaches Immich, Paperless and
   Samba on the main server. Adjust the IPs to your devices (machines page
   in the admin console), paste into *Access Controls*, save. **Save the
   previous ACL content first** so you can restore the default.
   Verify from the phone (WLAN off): Immich works, the router page no
   longer loads.
2. **Device approval:** *Settings → Device management → Manually approve new
   devices*. Existing devices stay approved.

Also worth it: MFA (ideally a passkey) on the identity provider account —
whoever owns that account owns your tailnet, and with it your LAN.

---

## Phase 9: Staying low-maintenance

- **OS security updates:** unattended-upgrades handles them on both Pis.
- **Everything else: one command a month.** Copy
  [`files/update-server.sh`](files/update-server.sh) to the main server
  (`~/update-server.sh`, `chmod +x`), adjust the variables at the top, and
  install `smartmontools` (`sudo apt install smartmontools`). From then on:
  ```bash
  ssh -t <user>@192.168.0.10 ./update-server.sh
  ```
  One run updates: system packages on **both** Pis, Paperless, Immich
  (fetches the upstream compose and rebuilds it via `transform-compose.py` —
  new `.env` variables are listed), the ML Pi (through the restricted key),
  prunes old images, checks SSD health, and probes all three services at the
  end. It asks for the main server's sudo password once.
  **Skim the Immich release notes first.** Stay away from auto-updaters
  (Watchtower) for Immich — its compose file changes between releases.
- **Back up the server's own data:** the Samba shares are backups *of other
  devices* — Paperless and Immich data lives only on this one drive. Immich
  writes nightly DB dumps to `UPLOAD_LOCATION/backups/` by default; make
  sure documents and photos leave the machine regularly (e.g. a backup tool
  like Pika Backup to an external drive, or rsync to another machine).

### Manual update path (fallback if the script fails)

Order: **back up first, then update.**

```bash
# 0. backups: check Immich dump exists in UPLOAD_LOCATION/backups/,
#    export Paperless:
cd /srv/docker/paperless && docker compose exec webserver document_exporter ../export

# 1. Paperless (uncritical, migrations run automatically):
docker compose pull && docker compose up -d

# 2. Immich — release notes first! Then:
cd /srv/docker/immich
wget -O docker-compose.yml.upstream https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
python3 transform-compose.py docker-compose.yml.upstream docker-compose.yml
docker compose pull && docker compose up -d

# 3. ML Pi:
ssh <user>@192.168.0.11
cd /srv/docker/immich-ml && docker compose pull && docker compose up -d

# 4. cleanup (on both):
docker image prune -f
```

**Rollback:** pin the image tag to the previous version
(`IMMICH_VERSION` in `.env`, or the image tag in the compose file), then
`docker compose up -d`. For database-migrating major upgrades (e.g.
Paperless 2 → 3), take a `pg_dump` before updating — image pinning alone
won't undo a migrated schema.

---

## Sensible build order

1. SD card → bootloader update → boot order USB
2. OS onto the SATA drive, remove SD, test boot
3. DHCP reservation, updates, unattended-upgrades
4. Samba with two nologin users
5. Docker (+ log rotation, cgroups) → Paperless → Immich
6. Second Pi: ML container + restricted update path
7. Tailscale on Pi + clients, key expiry off (server only), ACL, device approval
8. update-server.sh + backup routine

---

## Lessons learned (build: July 2026)

### Imager & first boot

- **The Flatpak imager can silently drop your customizations**
  (SSH/user/hostname). After writing, check that a filled-in `user-data`
  exists on the boot partition. Classic fallback, directly on the bootfs
  partition:
  ```bash
  openssl passwd -6                        # generate hash
  echo 'anna:<HASH>' > userconf.txt        # creates the user
  touch ssh                                # enables SSH
  ```
- Newer images (Trixie) use cloud-init: changing the `instance_id` in
  `meta-data` forces the first-boot setup to run again.
- rpi-clone is not in apt, only on GitHub — but works flawlessly for
  SD → drive migration.

### Booting from large drives (Pi 4)

- **The Pi 4 bootloader only boots GPT disks if the FAT32 boot partition
  sits at the start of the disk** (below ~1 TiB, ideally from sector 2048).
  A boot partition at the end fails — hybrid MBR doesn't help either.
- Robust fallback when USB boot acts up: the SD card provides only the
  kernel, root lives on the drive — put `root=PARTUUID=<drive-partition>`
  into the SD card's `cmdline.txt`.
- Check what actually booted:
  `od -An -tu4 /proc/device-tree/chosen/bootloader/boot-mode`
  (67108864 = USB, 16777216 = SD).

### USB-SATA bridges (most important lesson!)

- **Cheap bridges (e.g. Innostor IS611) can take down the entire USB bus
  under load — including the system drive** (root FS goes read-only, system
  crashes). Recognizable by endless resets in `dmesg`. Stress-test before
  big copy jobs:
  ```bash
  sudo dd if=/dev/sdX of=/dev/null bs=4M count=512 status=progress   # 2 GB read test
  sudo dmesg | grep -icE "reset|i/o error"                            # 0 = stable
  ```
- Stopgap for flaky bridges: plug into a **USB 2.0 port** (stable mode,
  ~38 MB/s). For permanent use only chips like ASM1153/JMS578.
- Stop the containers (`docker compose stop`) before large copies onto the
  system drive — limits the damage if the bus does flip.

### Protecting migration work

- Make the journal persistent **before** something goes wrong (crash logs
  don't survive a reboot otherwise):
  ```bash
  sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald
  ```
- Verify copies with checksums before destructive steps (empty output =
  bit-identical):
  ```bash
  sudo rsync -rnc --out-format='DIFF %n' /source/ /target/
  ```

### Samba

- Debian's default config ships ghost shares (`[homes]` exposes every user
  home, `print$` printer drivers). Disable in `smb.conf`: `available = no`
  under `[homes]`/`[printers]`/`[print$]`, plus `load printers = no` in
  `[global]`.
- The share name in square brackets is exactly what file managers display.

### Paperless-ngx

- `PAPERLESS_ALLOWED_HOSTS` must contain **every** access path (LAN IP,
  Tailscale IP, hostname) — otherwise HTTP 400.
- Create the superuser with `docker compose run --rm webserver
  createsuperuser` (not `exec`).
- Migrating an old instance: start the old stack (same Postgres version!) on
  a **copy** of the data, then `document_exporter` → `document_importer`
  into a **fresh** instance. The import carries over users and passwords.
- The 2 → 3 major upgrade only works from the last 2.x release (2.20.15),
  requires `PAPERLESS_SECRET_KEY` and `PAPERLESS_DBENGINE` to be set
  explicitly, and rebuilds the search index on first start. Take a
  `pg_dump` first — the schema migration is one-way.

### Immich

- Mount existing photo collections as a **read-only external library**
  instead of importing — the folder structure stays authoritative, no
  lock-in:
  ```yaml
  # under immich-server volumes:
  - /srv/photo-archive:/mnt/photos:ro
  ```
- **Enable the storage template before the first phone upload** (e.g.
  `{{y}}/{{MM}}/{{dd}}/{{y}}{{MM}}{{dd}}-{{filename}}`), or you get UUID
  file names. Avoid `{{album}}` — Immich moves files around when albums
  change.
- ML results (CLIP vectors, faces) live in the **main database**, not in
  the ML container — you can move, rebuild or reinstall the ML container
  freely without losing indexing work. Run "missing" jobs after changes,
  never "all" (that recomputes everything).
- The first full indexing run of a large archive takes days on a Pi — let
  it run, it only happens once.
- For WebP collections set the preview format to WebP (transparency). The
  OCR job (new in v3) is a CPU hog — turn it off for a pure photo archive.
- Set `DB_DATA_LOCATION` in `.env`, otherwise the database lands in the
  default location.
- **Duplicates:** exact checksums don't catch format differences
  (archive WebP ↔ phone JPG). Tool of choice: **Czkawka** "similar images"
  (perceptual), with the archive as reference folder. The **locked folder**
  is completely walled off via API (401) — only manual handling in the app,
  or a DB workaround (`UPDATE asset SET visibility='timeline' WHERE id IN
  (…)`, then deletable via API). The asset table is called `asset`
  (singular), the column `"libraryId"`.

### Tailscale

- **Android's "Private DNS" (DoT) overrides MagicDNS** → names don't
  resolve on the phone. Solution: disable "Use Tailscale DNS" in the app
  and use the stable tailnet IP.
- "Disable key expiry" **only for the server** — clients re-authenticate
  quickly, and expiry is what removes a lost device automatically.
- KTailctl (Flatpak GUI) needs socket access:
  `flatpak override --user --filesystem=/run/tailscale org.fkoehler.KTailctl`,
  plus `sudo tailscale set --operator=$USER`.
- Services behind Django/CSRF protection (Paperless) need the tailnet IP in
  their host list.
- Mounting SMB through the tunnel: `vers=3.1.1,sec=ntlmssp` (SMB 3.0 can
  throw `Operation not supported`).
- The ACL editor accepts comments (HuJSON) and validates on save — but
  **copy the old policy somewhere first**, there is no undo.
