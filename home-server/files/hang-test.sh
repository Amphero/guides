#!/bin/bash
# Checks that the kernel reports a task stuck on a frozen file system.
# hung_task_panic stays 0, all values are restored at the end.
#   sudo bash hang-test.sh
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

K=/proc/sys/kernel
IMG=/var/tmp/hangtest.img
MNT=/var/tmp/hangtest.mnt
OLD_TIMEOUT=$(cat $K/hung_task_timeout_secs)
OLD_INTERVAL=$(cat $K/hung_task_check_interval_secs)
OLD_PANIC=$(cat $K/hung_task_panic)
OLD_WARN=$(cat $K/hung_task_warnings)
WRITER=

cleanup() {
    fsfreeze -u "$MNT" 2>/dev/null
    [ -n "$WRITER" ] && wait "$WRITER" 2>/dev/null
    umount "$MNT" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
    rm -f "$IMG"
    echo "$OLD_TIMEOUT"  > $K/hung_task_timeout_secs
    echo "$OLD_INTERVAL" > $K/hung_task_check_interval_secs
    echo "$OLD_PANIC"    > $K/hung_task_panic
    echo "$OLD_WARN"     > $K/hung_task_warnings
    echo "cleaned up, values restored: timeout=$(cat $K/hung_task_timeout_secs)" \
         "interval=$(cat $K/hung_task_check_interval_secs)" \
         "panic=$(cat $K/hung_task_panic) warnings=$(cat $K/hung_task_warnings)"
}
trap cleanup EXIT

# never panic during this test
echo 0  > $K/hung_task_panic
echo 30 > $K/hung_task_timeout_secs
echo 5  > $K/hung_task_check_interval_secs
echo 10 > $K/hung_task_warnings

truncate -s 64M "$IMG"
mkfs.ext4 -q -F "$IMG"
mkdir -p "$MNT"
mount -o loop "$IMG" "$MNT"
fsfreeze -f "$MNT"

START=$(date +%s)
touch "$MNT/test" &
WRITER=$!
echo "test file system frozen, write hangs (PID $WRITER), waiting up to 75 s"

HIT=
for i in $(seq 15); do
    sleep 5
    HIT=$(journalctl -k --since "@$START" -o cat | grep -m1 "blocked for more than")
    [ -n "$HIT" ] && break
done

echo "process state: $(ps -o stat= -p "$WRITER" 2>/dev/null)"
if [ -n "$HIT" ]; then
    echo "DETECTED after $(( $(date +%s) - START )) s: $HIT"
else
    echo "NOT detected within 75 s"
fi
