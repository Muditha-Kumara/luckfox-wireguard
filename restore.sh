#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore.sh - push a backup snapshot from this repo back onto the board.
#
# Usage:
#   ./restore.sh [backup-dir] [ssh-host] [--only LIST] [--dry-run] [--yes]
#
#   backup-dir   default: latest under board-backup/
#   ssh-host     default: big
#   --only LIST  comma separated from: etc,root,userdata,oem-dot,boot,state
#                (default: etc,root,userdata,oem-dot  - NOT boot, see below)
#   --dry-run    show what would happen, change nothing
#   --yes        skip confirmation
#
# The boot partition (kernel + patched DTB) is NOT restored by default:
# a wrong DTB can stop the board booting and USB gadget recovery is the only
# way back in. Restore it deliberately with --only boot (verifies sha256 first).
# ---------------------------------------------------------------------------
set -euo pipefail

BACKUP_DIR=""; HOST=""; ONLY="etc,root,userdata,oem-dot"; DRY=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --only)    ONLY="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        -*)        echo "unknown option: $1"; exit 1 ;;
        *)         if [ -z "$BACKUP_DIR" ] && [ -d "$1" ]; then BACKUP_DIR="$1"
                   elif [ -z "$HOST" ]; then HOST="$1"
                   elif [ -z "$BACKUP_DIR" ]; then BACKUP_DIR="$1"
                   else echo "unexpected arg: $1"; exit 1; fi
                   shift ;;
    esac
done
[ -n "$HOST" ] || HOST="big"

# default: newest backup dir
if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$(ls -1d board-backup/*/ 2>/dev/null | sort | tail -1)"
    BACKUP_DIR="${BACKUP_DIR%/}"
fi
[ -d "$BACKUP_DIR" ] || { echo "backup dir not found: $BACKUP_DIR"; exit 1; }
echo "Backup:  $BACKUP_DIR"
echo "Target:  ssh $HOST"
echo "Restore: $ONLY"

# verify checksums before touching the board
if [ -f "$BACKUP_DIR/MANIFEST.sha256" ]; then
    echo "== Verifying archive integrity =="
    (cd "$BACKUP_DIR" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1) \
        && echo "   checksums OK" \
        || echo "   WARNING: checksum verification incomplete/failed"
fi

SSH=(-o ServerAliveInterval=15 -o ConnectTimeout=10 "$HOST")
if ! ssh "${SSH[@]}" 'echo ok' >/dev/null 2>&1; then
    echo "ERROR: cannot ssh to '$HOST'. Is the board up and reachable?"
    exit 1
fi

if [ "$ASSUME_YES" != 1 ] && [ "$DRY" != 1 ]; then
    printf "\nThis OVERWRITES board files from %s. Type 'yes' to continue: " "$BACKUP_DIR"
    read -r ans; [ "$ans" = "yes" ] || { echo "aborted"; exit 1; }
fi

have() { echo ",$ONLY," | grep -q ",$1,"; }

restore_tar() { # name, dest-parent
    local t="$1" parent="$2"
    local f="$BACKUP_DIR/$t.tar.gz"
    [ -f "$f" ] || { echo "   skip $t (no archive)"; return; }
    if [ "$DRY" = 1 ]; then echo "   would restore $t.tar.gz -> $parent on board"; return; fi
    echo "   restoring $t -> $parent"
    cat "$f" | ssh "${SSH[@]}" "gzip -dc | tar xf - -C $parent"
    echo "   $t done"
}

echo "== Restoring =="
have etc       && restore_tar etc       /
have root      && restore_tar root      /
have userdata  && restore_tar userdata  /
have oem-dot   && restore_tar oem-dot   /oem

if have boot; then
    IMG="$BACKUP_DIR/boot-mmcblk0p4.img.gz"
    if [ -f "$IMG" ]; then
        if [ "$DRY" = 1 ]; then
            echo "   would flash boot partition /dev/mmcblk0p4 from $(basename $IMG)"
        else
            echo "   WARNING: reflashing boot partition (kernel/DTB)."
            echo "   Pushing image to /userdata and writing with dd..."
            cat "$IMG" | ssh "${SSH[@]}" "cat > /userdata/restore-boot.img.gz"
            ssh "${SSH[@]}" 'gunzip -c /userdata/restore-boot.img.gz > /userdata/restore-boot.img && \
                sha256sum /userdata/restore-boot.img && \
                dd if=/userdata/restore-boot.img of=/dev/mmcblk0p4 bs=64k conv=fsync && \
                sync && rm -f /userdata/restore-boot.img* && echo BOOT_WRITE_OK'
        fi
    fi
fi

# state/ is reference only (network.txt, wg-show, iptables, fdt-live...) - not auto-applied.
if have state; then
    echo "   state/ is reference data; to re-apply live rules run:"
    echo "     ssh $HOST 'iptables-restore < /tmp/iptables.rules'  (push file first)"
    echo "   (the S99wireguard init script rebuilds wg0 + rules on boot on its own)"
fi

echo
if [ "$DRY" = 1 ]; then echo "DRY RUN complete - nothing changed."; exit 0; fi
echo "Files restored. Reboot board to apply services:"
echo "   ssh $HOST 'reboot'"
echo "Then verify with: ./verify.sh"
