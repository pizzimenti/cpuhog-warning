# cpuhog-warning

A KDE desktop notification service that monitors CPU usage and alerts when a process sustains high CPU for too long.

## Behavior

- Checks every 30 seconds
- Alerts when any non-whitelisted process exceeds **20% of a single core** for more than **2 minutes**
- Uses `/proc` deltas instead of `ps`, so CPU usage is based on work done during the last scan interval
- Re-alerts every **5 minutes** if the process keeps hogging CPU
- Each notification has three options:
  - **Kill Process** — sends SIGTERM to the offending PID
  - **Whitelist** — silences alerts for this PID until it exits naturally
  - **Close (×)** — dismiss for now; re-alerts in 5 minutes
- `plasmashell` is tracked in the same scan with its own **10% / 30s** thresholds

## Install

```bash
bash install.sh
```

Requires `pkexec` (KDE polkit agent) to install the binary to `/usr/local/bin/`.

## Configuration

Edit the top of `cpuhog-warning.sh` before installing:

| Variable    | Default | Description                                      |
|-------------|---------|--------------------------------------------------|
| `WHITELIST` | lm-studio | Process name substrings exempt from alerting   |
| `THRESHOLD` | 20      | CPU % per core to trigger tracking              |
| `SUSTAIN`   | 120     | Seconds a process must stay above threshold     |
| `REALERT`   | 300     | Seconds between repeat alerts for same process  |
| `INTERVAL`  | 30      | Seconds between checks                          |

## Files

| Path | Description |
|------|-------------|
| `/usr/local/bin/cpuhog-warning` | Installed daemon |
| `~/.config/systemd/user/cpuhog-warning.service` | Systemd user unit |
| `~/.local/share/cpuhog-warning/log` | Alert log |
| `~/.local/share/cpuhog-warning/actions` | Async notification action handoff |

## Logs

```bash
journalctl --user -u cpuhog-warning.service -f
tail -f ~/.local/share/cpuhog-warning/log
```

## Service management

```bash
systemctl --user status cpuhog-warning
systemctl --user restart cpuhog-warning
systemctl --user stop cpuhog-warning
```
