#!/bin/bash
# Exports the Paperless archive as readable files into a folder of the Samba
# share. That folder is both the restorable backup and plain file access to the
# documents. Called by paperless-export.timer, see the setup guide.
set -euo pipefail

CONTAINER=paperless-webserver-1
TARGET_HOST=/srv/data/data/anna/Dokumente/Akten
TARGET_CONTAINER=/usr/src/paperless/akten
OWNER=anna:anna

# The timer may fire right after a boot, so wait for the container.
for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" = healthy ] && break
    sleep 5
done

docker exec "$CONTAINER" document_exporter "$TARGET_CONTAINER" \
    --use-filename-format --no-thumbnail --delete --no-progress-bar
chown -R "$OWNER" "$TARGET_HOST"
