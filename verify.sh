#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify.sh - compare the LIVE board against the latest backup snapshot.
# Reports drift so you can see exactly what experiments changed.
#
# Usage: ./verify.sh [ssh-host] [backup-dir]
# ---------------------------------------------------------------------------
set -uo pipefail

HOST="${1:-big}"
BACKUP_DIR="${2:-$(ls -1d board-backup/*/ 2>/dev/null | sort | tail -1)}"
BACKUP_DIR="${BACKUP_DIR%/}"
[ -d "$BACKUP_DIR" ] || { echo "backup dir not found: $BACKUP_DIR"; exit 1; }

echo "Comparing live '$HOST' against $BACKUP_DIR"
echo "============================================================"

# 1) checksums of stored archives
echo "-- archive integrity --"
(cd "$BACKUP_DIR" && sha256sum -c MANIFEST.sha256 2>/dev/null) \
    | grep -v ': OK$' | sed 's/^/   DRIFT\/FAIL: /' \
    || true
echo "   (no output above = all archives intact)"

# 2) live vs backup: /etc file list (busybox-safe: no -printf)
echo
echo "-- /etc differences (live vs backup) --"
ssh "$HOST" "find /etc \( -type f -o -type l \) 2>/dev/null | sed 's|^/||' | LC_ALL=C sort" > /tmp/etc-live.txt
tar tzf "$BACKUP_DIR/etc.tar.gz" 2>/dev/null | grep -v '/$' | LC_ALL=C sort > /tmp/etc-backup.txt
diff /tmp/etc-backup.txt /tmp/etc-live.txt > /dev/null 2>&1 \
    && echo "   /etc file list identical ($(wc -l < /tmp/etc-live.txt) files)" \
    || { echo "   /etc DIFFERS (< backup, > live):"; diff /tmp/etc-backup.txt /tmp/etc-live.txt | head -40 | sed 's/^/     /'; }

# 3) key runtime facts
echo
echo "-- runtime drift (live board) --"
ssh "$HOST" 'sh -s' <<'REMOTE'
echo -n "   wg0 up: "; ip link show wg0 >/dev/null 2>&1 && echo yes || echo "NO"
echo -n "   wlan0 power_save: "; iw dev wlan0 get power_save 2>/dev/null | tail -1
echo -n "   wifi-pm-keeper running: "; pgrep -f wifi-pm-keeper >/dev/null && echo yes || echo "NO"
echo -n "   ip_forward: "; cat /proc/sys/net/ipv4/ip_forward
echo "   luckfox.cfg:"; sed 's/^/     /' /etc/luckfox.cfg
echo "   forward rules:"; iptables-save 2>/dev/null | grep FORWARD | sed 's/^/     /'
REMOTE

echo
echo "============================================================"
echo "If anything above changed vs expectations, restore with:  ./restore.sh"
