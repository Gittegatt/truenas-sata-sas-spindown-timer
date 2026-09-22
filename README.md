# TrueNAS SATA/SAS Spindown Timer

A lightweight SATA and SAS disk spindown timer for TrueNAS SCALE 25.10.

The script monitors real disk I/O through Linux kernel counters and puts an idle disk into standby after a configurable timeout. It is designed to avoid using normal disk reads as an activity probe, which could wake a sleeping disk.

Current script version: `v1.0.0`

## Background and attribution

This project is based on the work and concepts from:

- [ngandrass/truenas-spindown-timer](https://github.com/ngandrass/truenas-spindown-timer)

The upstream project provides a much more feature-rich TrueNAS spindown implementation and is licensed under the MIT License. This project is a smaller TrueNAS SCALE 25.10-focused implementation with a different monitoring approach based on `/sys/block/<disk>/stat` and `smartctl`.

For TrueNAS 25.10, this setup is also intended to be used together with the community middleware patch published by `ark` in the TrueNAS Community Forums:

- [HDD Sleep/Spindown/Standby - post #71 by ark](https://forums.truenas.com/t/hdd-sleep-spindown-standby/13325/71)

See [TrueNAS 25.10 and the Ark patch](#truenas-2510-and-the-ark-patch) before applying it.

## Differences from the upstream project

This project is intentionally smaller and more focused than `ngandrass/truenas-spindown-timer`. It is not intended to replace the upstream project or provide all of its features.

| Area | This project | Upstream `ngandrass/truenas-spindown-timer` |
| --- | --- | --- |
| Target platform | Focused on TrueNAS SCALE 25.10 | Supports TrueNAS CORE and TrueNAS SCALE |
| I/O activity detection | Reads completed read/write counters from `/sys/block/<disk>/stat` | Uses `iostat` to monitor disk I/O |
| Disk control | Uses `smartctl` | Supports `camcontrol`, `smartctl`, and `hdparm` depending on platform/configuration |
| Scope | Disk-level monitoring of selected or automatically detected `sd*` devices | Disk-level and ZFS pool-level operation |
| Configuration | One timeout and poll interval shared by monitored disks | Supports additional configuration such as per-disk/pool timeouts and ignored disks/pools |
| Logging and diagnostics | Standard output plus optional check mode | Includes quiet, verbose, syslog, check, and dry-run modes |
| Automatic shutdown | Not implemented | Supported |
| One-shot mode | Runs one normal loop iteration and exits; the configured idle timeout still applies | Performs one I/O polling interval and can spin down drives considered idle for that interval, ignoring the normal timeout |

The main design difference is the activity detection method. This script samples Linux kernel block-device counters directly instead of running an `iostat` monitoring interval. A change in the completed read/write counters resets that disk's idle timer. Disk power state is checked separately with `smartctl --nocheck standby`.

The simpler design also means that several upstream features are deliberately not included here. If you need ZFS pool mode, per-disk timeout configuration, dry-run mode, syslog logging, automatic shutdown, TrueNAS CORE support, or selectable disk control tools, use the upstream project instead.

## Features

- Per-disk idle timers
- SATA and SAS disk support
- I/O detection through `/sys/block/<disk>/stat`
- Disk state checks with `smartctl --nocheck standby`
- Configurable idle timeout
- Configurable polling interval
- Manual selection of individual disks
- Automatic detection of `sd*` devices
- Optional status output
- Single-instance protection with `flock`
- One-shot execution mode

## Compatibility

Target platform:

- TrueNAS SCALE 25.10 (Goldeye)

Successfully tested with:

| TrueNAS SCALE version | Status |
| :--- | :--- |
| `25.10.7` | Successfully tested |

The script has been used with TrueNAS SCALE 25.10.x. It relies on Linux `/sys/block`, Bash, `smartctl`, and `flock`, so it is not intended for TrueNAS CORE / FreeBSD.

TrueNAS updates can change middleware behavior. If you use the Ark patch described below, check patch compatibility again after every TrueNAS update.

## Requirements

The following commands or facilities are required:

- Bash
- `smartctl` from smartmontools
- `flock` from util-linux
- Linux `/sys/block`
- Root privileges

The script creates its lock file at:

```text
/var/run/truenas-sata-sas-spindown-timer.lock
```

Run it as root, for example with `sudo`.

## Installation

Copy the script to a persistent location and make it executable:

```bash
chmod +x truenas-sata-sas-spindown-timer.sh
```

Then run it with the desired options.

## Usage

```text
./truenas-sata-sas-spindown-timer.sh [-h] [-m] [-i <disk>] [-t <timeout>] [-p <poll>] [-o] [-c]
```

Options:

| Option | Description |
| --- | --- |
| `-t TIMEOUT` | Idle time in seconds before spindown. Default: `3600` |
| `-p POLL_TIME` | Poll interval in seconds. Default: `600` |
| `-m` | Manual mode. Only disks explicitly supplied with `-i` are monitored |
| `-i <disk>` | Disk to monitor, for example `sda`. Can be repeated |
| `-o` | Run one loop iteration and exit |
| `-c` | Print disk state on every poll. Spindown remains active |
| `-h` | Show help |

### Monitor selected disks only

For example, monitor only `sda` and `sdd`:

```bash
sudo ./truenas-sata-sas-spindown-timer.sh -m -i sda -i sdd
```

With a 30 minute idle timeout and a 60 second polling interval:

```bash
sudo ./truenas-sata-sas-spindown-timer.sh -m -i sda -i sdd -t 1800 -p 60
```

Enable status output as well:

```bash
sudo ./truenas-sata-sas-spindown-timer.sh -m -i sda -i sdd -t 1800 -p 60 -c
```

When using an absolute path, the same command can look like this:

```bash
/bin/bash /mnt/tank/scripts/truenas-sata-sas-spindown-timer/truenas-sata-sas-spindown-timer.sh -m -i sda -i sdd -t 1800 -p 60
```

Replace `/mnt/tank/scripts/truenas-sata-sas-spindown-timer` with the persistent location used on your system.

### Automatic mode: all `sd*` devices

Without `-m`, the script detects all block devices whose names start with `sd`:

```bash
sudo ./truenas-sata-sas-spindown-timer.sh
```

Important: automatic mode does not check whether a device is rotational. An SSD or USB storage device exposed as `sdX` can therefore also be selected.

For mixed HDD/SSD systems, manual mode or the dynamic rotational selection below is recommended.

### Dynamic selection of rotational disks

The following command dynamically detects `sd*` devices with `queue/rotational=1`, builds the corresponding `-m -i ...` arguments, and starts the timer in the foreground:

```bash
ARGS=(-m); for p in /sys/block/sd*; do [[ -r "$p/queue/rotational" && "$(cat "$p/queue/rotational")" == "1" ]] && ARGS+=(-i "$(basename "$p")"); done; /bin/bash /mnt/tank/scripts/truenas-sata-sas-spindown-timer/truenas-sata-sas-spindown-timer.sh "${ARGS[@]}" -t 1800 -p 60
```

This keeps the rotational-device filtering outside the timer itself. The timer receives only the detected HDDs through manual mode.

### TrueNAS Post Init with `tmux`

For a long-running TrueNAS Init/Shutdown Script, a detached `tmux` session can be used. This example also logs the detected HDD list and script output:

```bash
tmux has-session -t spindown-timer 2>/dev/null || tmux new-session -d -s spindown-timer "/bin/bash -lc 'ARGS=(-m); for p in /sys/block/sd*; do [[ -r \"\$p/queue/rotational\" && \"\$(cat \"\$p/queue/rotational\")\" == \"1\" ]] && ARGS+=(-i \"\$(basename \"\$p\")\"); done; echo \"===== spindown timer restart \$(date) =====\" >> /mnt/tank/scripts/truenas-sata-sas-spindown-timer/spindown.log; echo \"Detected HDDs: \${ARGS[*]}\" >> /mnt/tank/scripts/truenas-sata-sas-spindown-timer/spindown.log; /bin/bash /mnt/tank/scripts/truenas-sata-sas-spindown-timer/truenas-sata-sas-spindown-timer.sh \"\${ARGS[@]}\" -t 1800 -p 60' 2>&1 | tee -a /mnt/tank/scripts/truenas-sata-sas-spindown-timer/spindown.log"
```

For TrueNAS, configure this as:

| Setting | Value |
| --- | --- |
| Type | `Command` |
| When | `Post Init` |
| Enabled | Yes |

Replace the example `/mnt/tank/scripts/...` path with your actual persistent script location. You can verify the installed `tmux` path with `command -v tmux` and use the absolute path in the Init command if desired.

### TrueNAS Post Init without `tmux`

The same dynamic rotational-device selection can be started in the background with `nohup` instead of `tmux`:

```bash
nohup /bin/bash -lc 'ARGS=(-m); for p in /sys/block/sd*; do [[ -r "$p/queue/rotational" && "$(cat "$p/queue/rotational")" == "1" ]] && ARGS+=(-i "$(basename "$p")"); done; /bin/bash /mnt/tank/scripts/truenas-sata-sas-spindown-timer/truenas-sata-sas-spindown-timer.sh "${ARGS[@]}" -t 1800 -p 60' >> /mnt/tank/scripts/truenas-sata-sas-spindown-timer/spindown.log 2>&1 &
```

This version does not provide a detachable interactive session, but it prevents the long-running timer from blocking the Init task and keeps its output in `spindown.log`.

## Rotational disk selection

The script itself intentionally does not filter by `/sys/block/<disk>/queue/rotational`.

You can list currently detected rotational `sd*` devices with:

```bash
for p in /sys/block/sd*; do
    [ "$(cat "$p/queue/rotational" 2>/dev/null)" = "1" ] && basename "$p"
done
```

Pass only the desired results to the script with `-m` and repeated `-i` options.

Example:

```bash
sudo ./truenas-sata-sas-spindown-timer.sh -m -i sda -i sdd -t 1800 -p 60
```

Linux `sdX` names can change after a reboot. Always verify the device mapping before using a persistent list of device names.

## How it works

For each monitored disk, the script keeps an independent idle timer.

### 1. I/O activity detection

The script reads:

```text
/sys/block/<disk>/stat
```

It uses the completed read and write counters from the kernel. Reading these counters does not require issuing a normal I/O request to the disk.

If the counters change between polls, the idle timer for that disk is reset.

### 2. Power state check

The current disk state is checked with:

```bash
smartctl -i --nocheck standby /dev/<disk>
```

The script treats output containing `STANDBY` as standby. Otherwise the disk is considered active.

### 3. Spindown

When the disk has had no detected I/O for at least the configured timeout and is not already in standby, the script runs:

```bash
smartctl -s standby,now /dev/<disk>
```

The timer and I/O baseline are then reset for that disk.

## One-shot mode

`-o` performs one normal loop iteration and then exits.

It does not bypass the configured idle timeout. Since idle timers are initialized when the script starts, one-shot mode with the default timeout will normally only report/check the initial state and exit.

## Check mode

`-c` prints the state of each monitored disk on every poll, including the current idle time and I/O counter.

Check mode is not a dry-run mode. Spindown remains enabled.

## TrueNAS 25.10 and the Ark patch

TrueNAS SCALE 25.10 can perform background operations that interfere with disk standby or wake disks again. This project has been used together with the community patch published by `ark` in the TrueNAS forum thread linked above.

The patch is external to this repository and is not an official TrueNAS/iXsystems modification.

Ark originally published the patch for TrueNAS `25.10.0.1`. Forum users later reported that the same patch applied cleanly to `25.10.2`, but you should not assume compatibility with every later TrueNAS build. Review the current forum discussion before applying it to another release.

### Applying the patch

Download the patch from the original forum post and remove the `.txt` extension if necessary. Then, from the TrueNAS shell:

```bash
cd /
sudo /usr/local/libexec/disable-rootfs-protection
sudo patch --verbose -N -p0 -i /path/to/spindown.patch
```

Reboot TrueNAS afterwards.

The original patch author states that the patch must be reapplied after TrueNAS updates.

### Important patch warning

The Ark patch modifies TrueNAS system files and is unsupported by iXsystems. Applying it is at your own risk and can affect supportability.

The patch author also notes that allowing disks to remain asleep for long periods can reduce the opportunities TrueNAS has to perform SMART health checks while those disks are in standby.

Later posts in the same forum thread contain additional community revisions and discussion. This README intentionally references Ark's original post as the basis used with this setup. Check the thread before applying any patch to a newer TrueNAS release.

## Running at startup on TrueNAS

TrueNAS SCALE 25.10 provides Init/Shutdown Scripts under:

```text
System > Advanced Settings > Init/Shutdown Scripts
```

The script uses a Bash shebang, so make sure the first line remains:

```bash
#!/bin/bash
```

Because this spindown timer is a long-running process, start it in a way that does not block the TrueNAS boot task. A detached session or equivalent wrapper can be used for this purpose.

For systems with both HDDs and SSDs, the startup wrapper can dynamically select only devices with `queue/rotational=1` and then call this script in manual mode with repeated `-i` arguments.

## Operational notes

- Any real disk I/O resets that disk's idle timer.
- Applications, VMs, datasets, monitoring, SMART activity, scrubs, replication, or other services can keep a disk active.
- The script cannot make a disk remain asleep while another process continues to access it.
- Very short timeout values can cause excessive start/stop cycles and additional mechanical wear.
- Verify your disk state, workload, SMART data, and start/stop counts when tuning the timeout.
- Do not assume `sdX` device names are stable across reboots.

## Credits

This project builds on work by the TrueNAS community.

Primary upstream project:

- Niels Gandrass - [ngandrass/truenas-spindown-timer](https://github.com/ngandrass/truenas-spindown-timer)

TrueNAS 25.10 middleware patch used with this setup:

- `ark` - [TrueNAS Community Forums, HDD Sleep/Spindown/Standby, post #71](https://forums.truenas.com/t/hdd-sleep-spindown-standby/13325/71)

Thanks to the upstream authors and TrueNAS community members who investigated disk standby behavior on TrueNAS SCALE.

## License and upstream notice

The upstream `ngandrass/truenas-spindown-timer` project is distributed under the MIT License:

- [Upstream LICENSE](https://github.com/ngandrass/truenas-spindown-timer/blob/master/LICENSE)

If code from the upstream project is copied or adapted in this repository, retain the applicable upstream copyright and MIT license notice as required by that license.

The Ark patch is a separate external community modification. Refer to the original forum post for its source, warnings, and current compatibility information.

## AI Notice

AI-assisted coding tools were used during the development of this project.

Use of this source code, including for AI or machine-learning training, fine-tuning, dataset creation, and model improvement, is subject to the terms of the MIT License.

This notice does not impose any additional restrictions, does not apply to third-party material beyond its respective terms, and does not override applicable statutory rights or exceptions.

## ☕ Support the project

If you enjoy the project and would like to support its development, a small contribution is always appreciated.

[Support me on Ko-fi](https://ko-fi.com/gittegatt)

[Support me on buymeacoffee](https://buymeacoffee.com/gittegatt)
