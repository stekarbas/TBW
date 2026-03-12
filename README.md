# TBW

`tbw` is a Bash script that reports SSD/NVMe wear and health data for all
non-rotational disks in the system.

It reads SMART information via `smartctl` and prints a compact table with:

- `DEVICE`
- `MODEL`
- `SIZE`
- `USED`
- `TBW` (terabytes written, decimal TB)
- `WEAR` (estimated wear percentage)
- `HEALTH` (SMART overall status)
- `TEMP`
- `POWER_ON` (power-on hours)

## Requirements

- Linux
- `smartctl` (from `smartmontools`)
- `lsblk`, `awk`, `sed`, `tr`, `grep`, `df`
- `ssh` (for remote mode; requires `/usr/local/bin/tbw` on each target host)
- Root privileges (required by `smartctl` on most systems)

## Usage

```bash
./tbw
```

Run against one or more remote hosts over SSH:

```bash
./tbw server1
./tbw server1 server2 server3
```

## Notes

- The script auto-detects SSD/NVMe devices (`ROTA=0` from `lsblk`).
- `USED` is derived from mounted filesystems on partitions belonging to each
  disk.
- Some SMART attributes differ by vendor/model, so unavailable metrics are
  shown as `-`.
- The script prompts for `sudo` when needed, both locally and on remote hosts.

## One Prompt Setup (Recommended)

To avoid repeated password prompts across many hosts:

1. Configure SSH key-based authentication from your client to each server.
2. Install this script as `/usr/local/bin/tbw` on each server.
3. Add a restricted sudoers rule (with `visudo`) for your user:

```sudoers
<user> ALL=(root) NOPASSWD: /usr/local/bin/tbw --as-root
```

Then remote runs can be passwordless:

```bash
./tbw server1 server2 server3
```
