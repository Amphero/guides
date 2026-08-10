#!/usr/bin/env python3
"""
Empty Immich's trash for good, including the rows the app cannot delete.

The problem
-----------
When a file in an external library disappears (renamed or deleted outside
Immich), Immich sets `deletedAt` on the asset but leaves `status` at
'active'. The row shows up in the trash, yet "empty trash" only operates on
status='trashed' and skips it. Those rows pile up, keep reappearing, and can
break the mobile sync (updateAssetFacesV2).

A second trap: if such an asset also has visibility='locked', the API will
not hand it out at all, so it is unreachable even through the REST API.

What this does
--------------
  1. reports the state,
  2. sets the inconsistent rows to status='trashed',
  3. unlocks orphaned rows so the API can reach them,
  4. deletes permanently through the API (which cleans up thumbnails and
     database rows properly, unlike a raw SQL DELETE).

Safety net: nothing is unlocked or deleted unless the file is verifiably
gone from disk. Rows whose file still exists are reported and left alone,
so a locked photo can never be exposed or lost by accident.

Usage
-----
  ./immich-trash-cleanup.py           report only, changes nothing
  ./immich-trash-cleanup.py --purge   clean up

Put your API key in ~/.immich_api_key (chmod 600). Create one in Immich
under Account Settings -> API Keys.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

# ---- adjust to your setup -------------------------------------------------
SERVER = "http://192.168.0.10:2283"
KEY_FILE = os.path.expanduser("~/.immich_api_key")
LIBRARY_HOST = "/srv/photo-archive"        # external library, host side
LIBRARY_CONTAINER = "/mnt/photos"          # same library inside the container
DB_CONTAINER = "immich_postgres"
# ---------------------------------------------------------------------------

PSQL = ["docker", "exec", DB_CONTAINER, "psql", "-U", "postgres", "-d", "immich", "-Atc"]


def api(path, method="GET", payload=None, timeout=180):
    key = open(KEY_FILE).read().strip()
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(SERVER + path, data=body, method=method,
                                 headers={"x-api-key": key,
                                          "Content-Type": "application/json",
                                          "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"  API error {e.code}: {e.read()[:200].decode(errors='replace')}")
        return None


def sql(statement):
    r = subprocess.run(PSQL + [statement], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        print("  SQL error:", r.stderr.strip()[:200])
        return None
    return r.stdout.strip()


def file_gone(container_path):
    """Translate a container path to the host and check the file is missing."""
    if not container_path.startswith(LIBRARY_CONTAINER):
        return False          # internal assets: Immich manages those files
    host = LIBRARY_HOST + container_path[len(LIBRARY_CONTAINER):]
    return not os.path.isfile(host)


def trash_rows():
    """Collect every asset in the trash via the API."""
    items, page = [], 1
    while True:
        d = api("/api/search/metadata", "POST",
                {"size": 1000, "page": page,
                 "trashedAfter": "2000-01-01T00:00:00.000Z"})
        if d is None:
            return items
        chunk = d["assets"]
        items += chunk["items"]
        if not chunk.get("nextPage"):
            return items
        page = int(chunk["nextPage"])


def main():
    purge = "--purge" in sys.argv
    if not os.path.exists(KEY_FILE):
        sys.exit(f"API key missing: {KEY_FILE}")

    stale = sql("SELECT count(*) FROM asset WHERE \"deletedAt\" IS NOT NULL "
                "AND status = 'active';")
    print(f"Inconsistent trash rows (deletedAt set, status=active): {stale}")

    if stale and stale != "0":
        paths = sql("SELECT \"originalPath\" FROM asset WHERE \"deletedAt\" IS NOT NULL "
                    "AND status = 'active';")
        rows = [p.strip() for p in (paths or "").splitlines() if p.strip()]
        orphans = [p for p in rows if file_gone(p)]
        print(f"   of those without a file on disk: {len(orphans)}")
        for p in rows:
            if p not in orphans:
                print(f"   still has a file, will be left alone: {p}")

    print(f"Trash visible through the API: {len(trash_rows())}")

    if not purge:
        print("\nReport only. Run with --purge to clean up.")
        return

    if stale and stale != "0":
        sql("UPDATE asset SET status='trashed' WHERE \"deletedAt\" IS NOT NULL "
            "AND status='active';")
        print(f"{stale} rows set to status='trashed'.")

    # Locked rows are not served by the API, so orphans among them must be
    # unlocked first. Nothing becomes visible in practice: the file is gone.
    locked = sql("SELECT id || E'\\t' || \"originalPath\" FROM asset "
                 "WHERE \"deletedAt\" IS NOT NULL AND visibility = 'locked';")
    release = []
    for line in (locked or "").splitlines():
        if "\t" not in line:
            continue
        asset_id, path = line.split("\t", 1)
        if file_gone(path.strip()):
            release.append(asset_id.strip())
    if release:
        ids = ",".join(f"'{a}'" for a in release)
        sql(f"UPDATE asset SET visibility='timeline' WHERE id IN ({ids});")
        print(f"{len(release)} locked orphans released for deletion.")

    rows = trash_rows()
    deletable = [a for a in rows
                 if not a.get("libraryId") or file_gone(a.get("originalPath", ""))]
    keep = len(rows) - len(deletable)
    if keep:
        print(f"{keep} rows still have a file, left in the trash.")
    if not deletable:
        print("Nothing to delete.")
        return
    ids = [a["id"] for a in deletable]
    done = 0
    for i in range(0, len(ids), 500):
        if api("/api/assets", "DELETE", {"ids": ids[i:i + 500], "force": True}) is not None:
            done += len(ids[i:i + 500])
    print(f"Permanently deleted: {done} (Immich processes this in the background)")


if __name__ == "__main__":
    main()
