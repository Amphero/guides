#!/bin/bash
# ML Pi update: system packages + Immich ML container.
# Triggered from the main server through a restricted SSH key
# (forced command in ~/.ssh/authorized_keys), runs as root via a
# sudoers exception that covers exactly this script.
set -euo pipefail

echo "[ml-pi] System updates..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq

echo "[ml-pi] Updating ML container..."
cd /srv/docker/immich-ml
docker compose pull --quiet
docker compose up -d
docker image prune -f >/dev/null

echo "[ml-pi] Running version:"
docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' immich_machine_learning || true
echo "[ml-pi] done."
