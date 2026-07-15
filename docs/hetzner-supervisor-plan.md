# Hetzner Supervisor Plan

Status: design draft, not deployed.

This plan makes Hetzner self-heal when `fabric` or the pty remote-control server
exits. The target is a per-machine supervisor owned by systemd user services, so
remote access survives process crashes and host reboots without requiring an
active SSH login.

## Goals

- Keep the Hetzner `fabric` daemon running under systemd with automatic restart.
- Keep the pty remote-control server running under systemd with automatic
  restart.
- Preserve `fabric --allow-shell` until pty remote attach fully replaces it.
- Make deploys diagnosable: verify binary version before restart and verify
  local health after restart.
- Log to both journald and the existing app logs where practical.
- Avoid using an interactive shell, `nohup`, detached helpers, or pty sessions
  as the long-term owner of either daemon.

## Non-Goals

- Do not deploy this while the fabric bus is down.
- Do not run the WAN drop test as part of supervisor installation.
- Do not replace pty's session-level persistence. systemd owns only the
  per-machine service processes; pty still owns PTY session state.

## Service Ownership

Use systemd user units for the Hetzner account that owns the fabric and pty
state. Enable lingering once so the user manager starts at boot and survives
logout:

```sh
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger
```

Expected:

```text
Linger=yes
```

The units live in:

```text
~/.config/systemd/user/fabric.service
~/.config/systemd/user/pty-remote-serve.service
```

## Fabric Unit

Use `fabric daemon` directly so systemd owns the foreground daemon process. Do
not use `fabric up`, because `up` is a convenience command that can spawn a
background daemon and then exit.

Draft:

```ini
[Unit]
Description=Fabric daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/fabric --home %h/.local/share/fabric daemon --allow-shell
Restart=on-failure
RestartSec=2s
StartLimitIntervalSec=60
StartLimitBurst=10
KillSignal=SIGTERM
TimeoutStopSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Notes:

- `--allow-shell` is intentionally explicit for the current Hetzner workflow.
  Long-term, move this policy into config so restarts do not depend on command
  memory.
- The daemon still writes its existing file log under
  `~/.local/share/fabric/logs/daemon.log` for app-level diagnostics.
- `Restart=on-failure` restarts crashes and non-zero exits. If we decide manual
  `fabric down` should also be healed immediately, change to `Restart=always`
  and use `systemctl --user stop fabric` for intentional stops.

## pty Remote-Serve Unit

The pty remote-control server should be owned the same way. The exact `ExecStart`
must match the pty-owned remote-serve entrypoint when pty finalizes it.

Draft shape:

```ini
[Unit]
Description=pty remote control server
After=fabric.service
Wants=fabric.service

[Service]
Type=simple
Environment=PTY_ROOT=%h/.local/share/pty
ExecStart=%h/.local/bin/pty remote-serve --socket %t/pty-remote.sock
Restart=on-failure
RestartSec=2s
StartLimitIntervalSec=60
StartLimitBurst=10
KillSignal=SIGTERM
TimeoutStopSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Open items before deploying this unit:

- Confirm the exact pty command name and flags for the long-running remote
  control server.
- Confirm the socket path and whether it should be under `%t`, `PTY_ROOT`, or
  another stable runtime directory.
- Confirm the fabric protocol name that exposes the remote-control socket.
- Decide whether `fabric expose <protocol> --socket <socket>` should be run by
  the pty service, the fabric service, or an explicit one-shot companion unit.

If exposure should be supervised too, prefer a one-shot unit ordered after both
services:

```ini
[Unit]
Description=Expose pty remote control over fabric
After=fabric.service pty-remote-serve.service
Requires=fabric.service pty-remote-serve.service

[Service]
Type=oneshot
ExecStart=%h/.local/bin/fabric expose pty-view --socket %t/pty-remote.sock
RemainAfterExit=yes

[Install]
WantedBy=default.target
```

## Deployment Flow

Run this only after Hetzner is reachable by SSH or a known-good control path.

1. Diagnose before changing anything:

```sh
pgrep -af fabric || true
tail -200 ~/.local/share/fabric/logs/daemon.log || true
tail -200 ~/.local/share/fabric/logs/restart.log || true
uptime
df -h
```

2. Install the intended binaries.

For fabric, use the existing release installer or copy the built binary to:

```text
~/.local/bin/fabric
```

For pty, install the matching pty build to:

```text
~/.local/bin/pty
```

3. Verify versions before restart:

```sh
~/.local/bin/fabric --version
~/.local/bin/pty --version
```

The fabric version must include the expected short git SHA.

4. Install or update unit files:

```sh
mkdir -p ~/.config/systemd/user
$EDITOR ~/.config/systemd/user/fabric.service
$EDITOR ~/.config/systemd/user/pty-remote-serve.service
systemctl --user daemon-reload
```

5. Enable lingering and services:

```sh
sudo loginctl enable-linger "$USER"
systemctl --user enable fabric.service
systemctl --user enable pty-remote-serve.service
```

6. Restart fabric first and verify locally before declaring the machine healthy:

```sh
systemctl --user restart fabric.service
systemctl --user status fabric.service --no-pager
journalctl --user -u fabric.service --no-pager -n 100
~/.local/bin/fabric status
```

The `fabric status` output must include:

```text
shell	allowed
```

This is a lockout check, not cosmetic output. If shell shows `disabled`, the
daemon is alive but remote shell recovery is broken; fix the unit command or
the future shell policy config before declaring the deploy healthy.

7. Restart pty remote-serve and verify locally:

```sh
systemctl --user restart pty-remote-serve.service
systemctl --user status pty-remote-serve.service --no-pager
journalctl --user -u pty-remote-serve.service --no-pager -n 100
```

8. From the Mac, verify remote reachability:

```sh
fabric ping hetzner
fabric status
```

Do not proceed to WAN drop testing until these checks are green.

## Recovery Commands

When Hetzner is sick and SSH is available, capture cause before restarting:

```sh
date -Is
hostname
uptime
pgrep -af fabric || true
pgrep -af pty || true
tail -200 ~/.local/share/fabric/logs/daemon.log || true
tail -200 ~/.local/share/fabric/logs/restart.log || true
systemctl --user status fabric.service --no-pager || true
systemctl --user status pty-remote-serve.service --no-pager || true
journalctl --user -u fabric.service --no-pager -n 200 || true
journalctl --user -u pty-remote-serve.service --no-pager -n 200 || true
df -h
free -h || true
```

Then restart:

```sh
systemctl --user restart fabric.service
systemctl --user restart pty-remote-serve.service
~/.local/bin/fabric status
```

## Acceptance Criteria

- `systemctl --user is-enabled fabric.service` prints `enabled`.
- `systemctl --user is-active fabric.service` prints `active`.
- `fabric status` works locally on Hetzner after a service restart.
- `fabric status` prints `shell	allowed` after a service restart.
- `fabric ping hetzner` works from the Mac after a service restart.
- Killing the fabric process causes systemd to restart it:

```sh
pkill -f 'fabric .* daemon'
sleep 3
systemctl --user is-active fabric.service
~/.local/bin/fabric status
```

- Rebooting Hetzner brings the fabric service back without SSH login, assuming
  lingering is enabled.
- The pty remote-control service passes the same restart and reboot checks once
  its exact command surface is finalized.

## Later Hardening

- Move `allow_shell` into fabric config so supervisor restarts do not need a
  command-line flag to preserve policy.
- Add `fabric doctor` to collect process, log, version, and reachability facts.
- Add `fabric status` fields for generic tunnel reconnecting state, attempts,
  last error, and buffered bytes before pty attach becomes user-facing over WAN.
- Consider a one-shot `fabric expose --persist` or config-backed exposures so
  ALPN/socket mappings survive daemon restarts without companion units.
