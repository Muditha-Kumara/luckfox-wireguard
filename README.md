# luckfox-wireguard — board configuration backup

Snapshot-and-restore toolkit for the **Luckfox Pico Zero** board (ssh host
`big`), so you can run experiments on the board and always roll it back to a
known-good state.

## Board facts (as of this backup)

| Item | Value |
|---|---|
| OS | Buildroot 2023.02.6, kernel 5.10.160, armv7l (Cortex-A7) |
| Rootfs | `/dev/mmcblk0p7` ext4, mounted **rw** → `/etc`, `/root` changes persist across reboot |
| Persistent data | `/userdata` (mmcblk0p6 ext4) — logs (`/var/log` symlink lives here), `wpa_supplicant.conf` |
| OEM | `/oem` (mmcblk0p5) — vendor binaries/libs + root dotfiles (`.ssh`, `.config`) |
| Boot partition | `/dev/mmcblk0p4` — uImage **+ patched DTB**. `luckfox-config` writes pin/USB settings here (e.g. `USB_MODE=host`). NOT visible anywhere else — this is why `backup.sh` dumps it. |
| Network | WiFi `SLEngineers` → `192.168.1.150` (dhcp), WireGuard `wg0` → `10.8.0.10`, NAT + **full-LAN routing** (rate-capped, see below) |
| Key custom services | `S99wireguard`, `S41wifinopm` + `/usr/bin/wifi-pm-keeper`, `S99python`, `S99usb0config`, `S35iptables` |

## What's in `board-backup/<timestamp>/`

| File | Contents |
|---|---|
| `etc.tar.gz` | entire `/etc` (init scripts, wireguard keys+conf, sshd, network, xtables) |
| `root.tar.gz` | `/root` (python apps, `authorized_keys`, certs) |
| `userdata.tar.gz` | `/userdata` (wifi creds, logs) |
| `oem-dot.tar.gz` | `/oem/.ssh`, `/oem/.config` (root home is `/oem`) |
| `boot-mmcblk0p4.img.gz` | raw boot partition (kernel + device tree) |
| `state/` | live snapshots: `network.txt`, `iptables.rules`, `wg-show.txt`, `system.txt`, `fdt-live.dtb`, `kernel-config.txt` |
| `MANIFEST.txt` / `MANIFEST.sha256` | inventory + integrity hashes |

## Daily workflow

```bash
./backup.sh            # snapshot board -> board-backup/<date_time>/ (+ git commit)
# ... run experiments on the board ...
./verify.sh            # diff live board vs latest backup (shows drift)
```

## Restoring

```bash
./restore.sh --dry-run          # see what would happen (latest backup)
./restore.sh                    # restore etc+root+userdata+oem-dot (asks yes)
./restore.sh board-backup/2026-10-08_2015   # a specific snapshot
./restore.sh --only etc         # restore just /etc
ssh big reboot                  # services come back on boot
./verify.sh                     # confirm
```

`restore.sh` **never touches the boot partition unless you ask**:

```bash
./restore.sh --only boot        # reflash kernel/DTB (e.g. after bricking
                                # luckfox-config changes). Board reboots into
                                # the backed-up device tree.
```

### Worst case: board won't boot at all
File-level restore is impossible; reflash the whole factory image over USB
(DFE/Maskrom via `luckfox` tooling), then restore `/etc` + `/root` +
`/userdata` from here — that brings back wireguard, wifi, and the python
apps. Keep `boot-mmcblk0p4.img.gz` as insurance against a bad DTB if you
want to avoid full reflash.

### Selective manual restore (no script)
```bash
# one file from the latest backup:
tar xzf board-backup/*/etc.tar.gz etc/init.d/S99wireguard -O | ssh big 'cat > /etc/init.d/S99wireguard && chmod +x /etc/init.d/S99wireguard'
```

## WireGuard forwarding policy

`/etc/init.d/S99wireguard` forwards tunnel clients to the **whole** `192.168.1.0/24`
(not just the ESP32), behind one MASQUERADE rule. Live rules:

```sh
iptables -S FORWARD          # limit ACCEPT wg0->wlan0, state ACCEPT wlan0->wg0, DROP rest
iptables -t nat -S POSTROUTING   # MASQUERADE -s 10.8.0.0/24 -o wlan0
```

The old ESP32-only allow-list is kept as `/etc/init.d/S99wireguard.bak.esponly`
(`cp ... /etc/init.d/S99wireguard` + restart to roll back).

The `wg0 -> wlan0` ACCEPT is gated by `--limit 1000/second --limit-burst 2000`, and the
trailing `DROP` is what makes the limit real — `-P FORWARD` is `ACCEPT`, so without the
DROP the limit rule would only ever pass packets. Tune without editing the file:
`RATE_CAP=500/second /etc/init.d/S99wireguard restart`.

**The rate cap is not full protection.** `xt_limit` is evaluated *after* WireGuard has
already decrypted the packet, so a hairpin loop still burns CPU on decrypt — it just
stops the LAN-side storm (router-GUI polling, ARP) from cascading. Keep the phone's
AllowedIPs narrow when on home WiFi; see gotchas below.

## Notes / gotchas

- Secrets are in here (`/etc/wireguard/privatekey`, wifi passphrase, TLS key,
  SSH host keys). This repo is the private backup — don't push it anywhere
  public.
- BusyBox quirks: board `tar` has no `-z` (scripts stream `tar | gzip`),
  `find` has no `-printf`, no `stat`. Scripts account for this.
- `state/` is reference data; `S99wireguard` rebuilds wg0/iptables on boot,
  so restoring the files is normally enough.
- The `/etc/ssh` host keys travel with `etc.tar.gz`, so SSH host-key prompts
  stay stable after restore.
