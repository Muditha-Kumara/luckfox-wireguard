#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# backup.sh - snapshot the Luckfox Pico Zero board ("ssh big") configuration
#             and state into board-backup/<timestamp>/ in this repo.
#
# Usage:   ./backup.sh [ssh-host]        # default host: big
#
# Captures:
#   * etc.tar.gz        - whole /etc (init scripts, wireguard, sshd, network)
#   * root.tar.gz       - /root (python apps, keys, authorized_keys)
#   * userdata.tar.gz   - /userdata (wpa_supplicant.conf, logs, ethaddr)
#   * oem-dot.tar.gz    - /oem/.ssh and /oem/.config (root home dotfiles)
#   * boot-mmcblk0p4.img.gz - raw boot partition (kernel + patched DTB:
#                             luckfox-config pin/USB-mode settings live here!)
#   * state/            - live runtime state: network, wg, iptables, fdt,
#                         kernel config, versions, lsmod, mounts
#   * MANIFEST.txt / MANIFEST.sha256 - integrity + inventory
# ---------------------------------------------------------------------------
set -euo pipefail

HOST="${1:-big}"
STAMP="$(date +%Y-%m-%d_%H%M)"
OUT="board-backup/$STAMP"
SSH=(-o ServerAliveInterval=15 -o ConnectTimeout=10 "$HOST")

echo "== Pre-flight: reachability check =="
ssh "${SSH[@]}" 'echo "   OK: $(uname -n) / $(cat /etc/os-release | grep PRETTY)"'

mkdir -p "$OUT/state"

echo "== 1/5 Filesystem archives =="
for src in etc root userdata; do
    # busybox tar has no -z, so pipe through gzip on the board
    ssh "${SSH[@]}" "tar cf - -C / $src 2>/dev/null | gzip -6" > "$OUT/$src.tar.gz"
    echo "   $src.tar.gz  $(du -h "$OUT/$src.tar.gz" | cut -f1)"
done
ssh "${SSH[@]}" "tar cf - -C /oem .ssh .config 2>/dev/null | gzip -6" > "$OUT/oem-dot.tar.gz"
echo "   oem-dot.tar.gz  $(du -h "$OUT/oem-dot.tar.gz" | cut -f1)"

echo "== 2/5 Boot partition dump (kernel + DT overlays from luckfox-config) =="
# mmcblk0p4 = 32M "boot" partition; contains uImage + DTB that luckfox-config
# patches (e.g. USB_MODE=host dr_mode). This is the ONLY backup of that state.
ssh "${SSH[@]}" "dd if=/dev/mmcblk0p4 bs=64k 2>/dev/null | gzip -6" > "$OUT/boot-mmcblk0p4.img.gz"
echo "   boot-mmcblk0p4.img.gz  $(du -h "$OUT/boot-mmcblk0p4.img.gz" | cut -f1)"

echo "== 3/5 Live device tree (as booted, with runtime overlays) =="
ssh "${SSH[@]}" "cat /sys/firmware/fdt" > "$OUT/state/fdt-live.dtb"
echo "   fdt-live.dtb  $(du -h "$OUT/state/fdt-live.dtb" | cut -f1)"

echo "== 4/5 Runtime state snapshots =="
ssh "${SSH[@]}" 'sh -s' > "$OUT/state/network.txt" <<'REMOTE'
echo "### ip addr"; ip addr
echo; echo "### ip link"; ip link
echo; echo "### ip route"; ip route
echo; echo "### ip neigh"; ip neigh
echo; echo "### iw dev"; iw dev
echo; echo "### resolv.conf"; cat /etc/resolv.conf 2>/dev/null
echo; echo "### hosts"; cat /etc/hosts
echo; echo "### hostname"; cat /etc/hostname 2>/dev/null
echo; echo "### wlan0 mac"; cat /sys/class/net/wlan0/address
echo; echo "### wpa_supplicant (/userdata)"; cat /userdata/wpa_supplicant.conf 2>/dev/null
REMOTE
ssh "${SSH[@]}" 'iptables-save 2>/dev/null' > "$OUT/state/iptables.rules"
ssh "${SSH[@]}" 'wg show all 2>/dev/null' > "$OUT/state/wg-show.txt"
ssh "${SSH[@]}" 'sh -s' > "$OUT/state/system.txt" <<'REMOTE'
echo "### date"; date
echo; echo "### uname"; uname -a
echo; echo "### os-release"; cat /etc/os-release
echo; echo "### cmdline"; cat /proc/cmdline
echo; echo "### mounts"; cat /proc/mounts
echo; echo "### df"; df
echo; echo "### lsmod"; lsmod
echo; echo "### versions"
wg -v 2>/dev/null | head -1
python3 -V 2>&1
ssh -V 2>&1 | head -1
iptables --version
busybox | head -1
echo; echo "### luckfox.cfg"; cat /etc/luckfox.cfg
echo; echo "### init.d"; ls /etc/init.d
echo; echo "### ssh host key pub md5"; md5sum /etc/ssh/ssh_host_*_key.pub 2>/dev/null
REMOTE
ssh "${SSH[@]}" 'zcat /proc/config.gz 2>/dev/null' > "$OUT/state/kernel-config.txt"

echo "== 5/5 Manifest =="
{
    echo "Luckfox board backup - created $(date -Iseconds) from host '$HOST'"
    echo "Board: $(ssh "${SSH[@]}" 'uname -n' 2>/dev/null)"
    echo
    echo "sha256sums:"
    (cd "$OUT" && sha256sum etc.tar.gz root.tar.gz userdata.tar.gz oem-dot.tar.gz \
        boot-mmcblk0p4.img.gz state/* 2>/dev/null)
} > "$OUT/MANIFEST.txt"
(cd "$OUT" && sha256sum etc.tar.gz root.tar.gz userdata.tar.gz oem-dot.tar.gz \
    boot-mmcblk0p4.img.gz state/* > MANIFEST.sha256 2>/dev/null)

echo
echo "DONE: $OUT ($(du -sh "$OUT" | cut -f1))"
echo "Next: git add -A && git commit -m 'board backup $STAMP'"
