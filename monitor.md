# Android Root System Monitor

CLI-утилита для мониторинга системного состояния Android-устройств
с root-доступом (Magisk / KernelSU).

## Requirements

- Android 11+
- Root-доступ (Magisk 26+)
- BusyBox или Toybox
- Доступ к /proc и /sys

## Installation

git clone …
chmod +x monitor.sh

## Usage

./monitor.sh [options]

## Examples
./monitor.sh
./monitor.sh --quiet
./monitor.sh --no-logcat

## Exit Codes

| Code | Label      | Description                   |
|------|------------|-------------------------------|
|      |            |                               |
| 0    | OK         | All checks passed             |
| 1    | WARNING    | Non-critical issue detected   |
| 2    | CRITICAL   | Critical system condition     |
| 3    | INTERNAL   | Script internal error         |

## Output Structure

- STORAGE
- MEMORY
- CPU
- GPU
- BATTERY
- NETWORK
- LOGCAT
- TOP PROCESSES
- PARTITIONS
- SYSTEM INFO

## Options

--help          Show help and exit
--quiet         Disable colored output
--no-logcat     Skip logcat analysis
--loop <seconds> Run script after X seconds

## Known Limitations

- GPU load may be unavailable on some SoC
- Battery cycles are vendor-dependent
- Temperature readings depend on kernel support

## Internal Design Notes

- Bash-only by design
- No external dependencies
- Optimized for rooted Android environments
