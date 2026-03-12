# TBW

`tbw.sh` is a Bash script that reports SSD/NVMe wear and health data for all
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
- Root privileges (required by `smartctl` on most systems)

## Usage

```bash
sudo ./tbw.sh
```

## Notes

- The script auto-detects SSD/NVMe devices (`ROTA=0` from `lsblk`).
- `USED` is derived from mounted filesystems on partitions belonging to each
  disk.
- Some SMART attributes differ by vendor/model, so unavailable metrics are
  shown as `-`.
