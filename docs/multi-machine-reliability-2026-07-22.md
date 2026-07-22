# Multi-machine reliability + the roaming gap + nix-managed fabric

_Report for Nathan, 2026-07-22 by fabric-claude. Goal: make the multi-machine
(fabric) setup super-stable + reliable enough to share with others._

## TL;DR

1. **Reliability (real data).** Since the durable-fix swap (`9f5391b`, 2026-07-21
   17:33 CEST) the Mac↔hetz link has been **rock-solid**: ~16.4 h continuous
   daemon uptime, **0 daemon restarts, 0 endpoint recycles, 0 offline events, 1
   transient blip** (the swap itself). Peer stays **direct ~42 ms**. The one
   caveat is churn, not outage — see §1.
2. **The roaming gap is the real shareability blocker.** Root cause confirmed in
   code: fabric only reacts to **local** network changes and never actively
   probes whether a **peer** is still reachable, so a peer that roams (changes
   public IP/network) goes unreachable both ways until its daemon is manually
   restarted. Concrete fix proposed in §2.
3. **Nix-managed fabric** shape sketched in §3 (daemon derivation + nix-generated
   `peers.toml` / `config.toml` / `syncs.toml` + launchd/systemd service; identity
   stays an out-of-band secret).

---

## §1 — Reliability report (real data, not vibes)

**Window:** swap at 2026-07-21 17:33 CEST → 2026-07-22 09:58 CEST ≈ **16.4 h**.
**Source:** the daemon's `fabric::validation` telemetry
(`~/.local/share/fabric/logs/validation.log.*`, ~5 MB/day), `service.err.log`,
launchd/`ps` state, and `/tmp/st-fabric-sync.log` (a live round-trip liveness
proxy — every sync cycle is a successful Mac↔hetz pull+push).

| Metric | Value (post-swap) | Read |
| --- | --- | --- |
| Daemon uptime | **16.4 h, pid 57079 unchanged** | 0 restarts, 0 crashes; launchd KeepAlive present but never needed |
| Endpoint generation | **0 throughout** (5168 samples) | **Zero** endpoint recycles / rehomes |
| Health polls online | **2584 / 2584 = 100 % online** | 0 offline events |
| Peer transport | **direct**, 2–3 active remote addrs; **relay always present** (1967/1967 snapshots) | direct primary, relay standing by |
| Live latency | **41.9–44.5 ms** (5 samples), all-day 41–47 ms | tight, low-variance direct path |
| Errors post-swap | **1** transient dial "connection lost" (swap moment) | 0 unknown-peer, 0 recycles, 0 panics, 0 reconnects |
| Local network-change events | **617** in 16.4 h (~38/h) | see churn note below |
| Sync run process | up continuously since 2026-07-21 11:05 (1 start) | no crashes across outage+recovery+swap |
| Recent sync cycles | ~99.8 % clean (2 transient re-dials / ~1000 cycles, each self-heals in 1 cycle) | churn-induced, not outage |

**MTBF-ish:** since the durable fix, effectively **no failures** — 0 outages, 1
transient blip, 16.4 h and counting. The pre-fix instability was entirely the
peer-config split (fixed in `9f5391b`), not the transport.

**Churn note (secondary finding).** macOS emits a lot of network-change events
(617 in 16.4 h) from VPN `utun*` interfaces and rotating IPv6 privacy addresses.
Each one calls iroh `endpoint.network_change()` **and drops all tunnel
connections** (`rehome_after_network_change`, `daemon.rs:1113`). The endpoint
absorbed every one without a recycle (generation stayed 0), and the sync loop
re-dials, so the observable cost is only the occasional single-cycle re-dial.
Still, it is wasted churn worth damping later (e.g. only drop tunnels when the
default route / usable-address set actually changes, not on every privacy-addr
rotation).

**Telemetry gap (fix recommended).** Continuous **latency + direct-vs-relay
_selection_** is **not** recorded. `pathwatch` (`src/pathwatch.rs`) logs exactly
this — per-path `rtt_ms`, `app_rtt_ms`, and `selected=direct|relay` — but it is
**gated off** (`FABRIC_PATHWATCH_SECS` unset, `daemon.rs:2374`) and is
diagnostic-only. The periodic health poll deliberately **skips the peer echo
probe** (`peer_probe_attempted=false`, `daemon.rs:1155`), so the daemon records
"my endpoint is online" but never "peer X is reachable, via which path, at what
RTT." Turning that probe on is the same change that closes the roaming gap (§2)
and gives us the latency history — one fix, two wins.

---

## §2 — The roaming gap (priority reliability fix)

**Symptom (known):** when a peer's public IP/network changes, the direct iroh
path dies and does **not** auto-fail-over to relay; the peer is unreachable both
ways until the affected daemon is manually restarted. A laptop that moves
networks silently drops.

**Root cause (confirmed in code):**

- fabric's only reactive recovery is `run_network_rehome_loop`
  (`daemon.rs:1596`), driven **entirely by the local** `netwatch::netmon::Monitor`
  — local interface/route changes only.
- On a local change it debounces, then `rehome_after_network_change`
  (`daemon.rs:1098`): calls iroh `endpoint.network_change()` (re-probe / re-STUN /
  re-discover) + `drop_tunnel_connections()`, then checks recovery via
  `endpoint_health_recovered` = **`endpoint.online()`** (the _local_ endpoint has a
  relay home), and recycles the endpoint only if that fails.
- **The health check verifies the local endpoint is online, not that any specific
  peer is reachable** (`peer_probe_attempted=false peer_reachable=false` in every
  health log). And the loop **only fires on local network changes.**

So when a **remote** peer roams and this machine's network is unchanged: (a) no
local netmon event → no rehome fires; (b) the established direct QUIC path to the
peer's old address silently blackholes; (c) fabric has **no active peer-liveness
probe** to notice; (d) nothing triggers a re-resolve / reconnect or relay
failover → the peer stays unreachable until a manual restart (which forces fresh
discovery + new connections). This matches the reported behavior exactly.

**Proposed fix — promote peer-liveness from diagnostic to load-bearing:**

1. **Always-on peer-health probe.** Run a periodic per-peer echo probe (the
   built-in echo ALPN, the same thing `fabric ping` uses) — either by wiring
   `pathwatch::probe_peer_paths` on by default, or a lighter `run_peer_health_loop`.
   Track consecutive failures, `selected` path (direct/relay), and RTT per peer.
2. **Peer-failure-triggered recovery (the key addition).** On _N_ consecutive
   probe failures for a peer — **without** waiting for a local network change —
   run the recovery ladder that `rehome_after_network_change` already implements,
   scoped to that peer: (a) drop the peer's tunnel connections, (b) re-resolve /
   re-inject its `EndpointAddr` and call `endpoint.network_change()` so iroh
   re-probes paths and can settle on relay, (c) escalate to `force_endpoint_recycle`
   only if still unreachable. Turns "manual restart required" into "self-heals in
   _N_ × probe-interval seconds."
3. **Guarantee relay as a real fallback.** Relay is connected today
   (`home_relays_connected=1`), but verify a roamed peer's **new** address is
   re-discoverable (pkarr/DNS/relay publish) and consider shortening iroh's
   direct-path validation timeout so a dead direct path fails over to relay faster
   instead of hanging on the stale path.
4. **Bonus:** this probe supplies the continuous latency + direct/relay telemetry
   §1 is missing.

**Effort / testing:** the recovery primitives already exist (`drop_tunnel_connections`,
`network_change`, `force_endpoint_recycle`, `recycle_endpoint_if_generation`) — the
new work is the probe loop + the failure→recovery trigger + a hysteresis/backoff so
a flapping peer doesn't thrash. Honest testing caveat: real roaming is hard to
unit-test; plan a live test (move a laptop between Wi-Fi/hotspot and confirm
self-heal without restart) plus a fault-injection unit test that simulates
consecutive probe failures driving the recovery ladder. **I can implement this on
your go** — it is the single highest-leverage reliability change for shareability.

---

## §3 — Nix-managed fabric (for Johannes)

Fabric's whole runtime surface is a binary + four files + one service, all of
which nix can produce per machine:

| Artifact | Path (default home) | Nix-managed? |
| --- | --- | --- |
| `fabric` binary | — | yes — `rustPlatform.buildRustPackage` from this repo (`Cargo.lock` present) |
| identity | `<home>/identity.toml` (secret key) | **no** — per-machine secret; provide via sops-nix/agenix, never generated by nix |
| peers allow-list | `~/.config/fabric/peers.toml` | yes — from a `peers` option |
| daemon config | `<home>/config.toml` (`allow_shell`, `exposes`, session caps) | yes — from options |
| declared syncs | `~/.config/fabric/syncs.toml` | yes — **exactly Nathan's model: nix produces the per-machine `syncs.toml`** |
| service | launchd agent (macOS) / systemd unit (Linux) | yes — module defines it directly instead of `fabric service install` |

**Module option sketch** (nix-darwin / NixOS `services.fabric`):

```nix
services.fabric = {
  enable = true;
  package = pkgs.fabric;                 # buildRustPackage derivation
  home = "/Users/johannes/.local/share/fabric";
  allowShell = false;
  memoryMaxMB = 1024;

  identityFile = config.sops.secrets."fabric/identity".path;  # secret, not in nix

  peers = [                              # -> ~/.config/fabric/peers.toml
    { id = "97d5b3d7…e34a152"; name = "hetzner"; }
    { id = "e6698b4d…36fccc5"; name = "mac"; }
  ];

  exposes = [                            # -> config.toml [[exposes]]
    { protocol = "st-sync"; exec = { argv = [ "rsync" "--server" "--daemon" "…" ]; maxChildren = 32; }; }
    # or { protocol = "web"; tcp = "127.0.0.1:8080"; } / { protocol = "x"; socket = "/run/x.sock"; }
  ];

  syncs = [                              # -> ~/.config/fabric/syncs.toml
    { name = "convoy-catalog-net"; folder = "/Users/johannes/.local/state/convoy/default/catalog"; peers = "*"; policy = "catalog"; }
    { name = "smalltalk-bus";      folder = "…/smalltalk"; peers = [ "hetzner" ]; policy = "bus"; include = [ "*.md" ]; }
  ];
};
```

**Rendered file shapes** (module writes these via `xdg.configFile` / an activation
script, matching the real TOML the daemon reads):

```toml
# peers.toml
[[peers]]
id = "97d5b3d7…"
name = "hetzner"

# config.toml
allow_shell = false
[[exposes]]
protocol = "st-sync"
[exposes.exec]
argv = ["rsync", "--server", "--daemon", "…"]
max_children = 32
[server_sessions]
max_total = 64

# syncs.toml
[[sync]]
name = "convoy-catalog-net"
folder = "/…/catalog"
peers = "*"
policy = "catalog"
```

**Service** = the existing launch args, expressed as a nix service:
`fabric --home <home> daemon [--allow-shell]`, with RunAtLoad/KeepAlive and an RSS
soft-limit (`memoryMaxMB`, default 1024). On NixOS: a `systemd.services.fabric`
(`Restart=always`, `MemoryMax=`). On macOS via nix-darwin:
`launchd.user.agents.fabric` (`KeepAlive = true`, `RunAtLoad = true`).

**Notes for Johannes:**
- **Identity is the one non-nix piece** — it is a secret and must persist per
  machine; generate once (`fabric key gen`) and feed via a secrets manager.
- **Reload on change:** a config change should run `fabric reload-peers` and
  `fabric sync reload` in the activation script (live-applies without a daemon
  restart — restart is the one thing to avoid, it blips the link).
- **`--home` caveat (now fixed):** the daemon is normally launched with
  `--home <default-state-root>`; as of `9f5391b` that resolves peers/config from
  `~/.config/fabric/` (same as the CLI). If nix uses a **non-default** home, note
  that peers/config then live **under that home** (`<home>/peers.toml`,
  `<home>/syncs.toml`) — keep every `fabric` invocation on the same `--home`.

---

## §4 — Stale launchd cruft on the Mac

- **`com.myobie.fabric.plist.stale-501`** — the old fabric plist I set aside
  during the swap. **Deleted** (2026-07-22; the new `com.compoundingtech.fabric`
  service has been stable 16 h+). Done.
- **`com.myobie.st-fabric-sync`** — the rsync-over-`fabric dial` **stopgap** sync
  loop (pid 1704, runs the `smalltalk-fabric97` worktree). **Not cruft — it is the
  currently load-bearing Mac↔hetz sync** (every healthy cycle in this report comes
  from it). It is a smalltalk-owned artifact, not fabric's. **Recommendation:**
  keep it until the real declarative `fabric sync` daemon replaces it (the durable
  successor to this whole stopgap), then retire the launchd job. Flagging for
  awareness; not mine to remove.
