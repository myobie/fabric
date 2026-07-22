# now — fabric working state

The living handoff for whoever owns fabric next (there was none before; keep this
current). This records what is DONE, what is IN FLIGHT, and what is NEXT — the
things the repo history alone does not carry.

_Last updated: 2026-07-21 by fabric-claude (opus). fabric 0.2.0 on origin main._

## Hotfix DEPLOYED — peer-config split (resolved 2026-07-21)

On 2026-07-21 the Mac↔hetz stopgap sync (rsync over `fabric dial`) failed in a
loop and blocked cos from reaching the hetz fleet. Root cause: the launchd
service launched the daemon as `--home ~/.local/share/fabric`, which (pre-fix)
made the dial path read `peers.toml` from under `--home` while the CLI writes
`~/.config/fabric/peers.toml`; a default-home `fabric add` migrated + deleted the
in-`--home` copy, leaving the daemon with zero peers on the dial path
(`unknown peer` in `service.err.log`) while `ping`/`status`/`shell` kept working.

- **Durable fix (commit `9f5391b`):** `FabricHome::resolve` treats an explicit
  `--home`/`FABRIC_HOME` equal to the default state root like the no-arg default
  (peers from `~/.config/fabric/`); a genuinely different `--home` stays isolated.
  Unit-tested (`resolve_from` + 6 regression tests).
- **DEPLOYED:** as of ~17:33 the Mac daemon runs the fixed binary
  (`0.2.0+9f5391b`, pid rotates under launchd) — swapped via stop-old →
  `fabric service install`. Verified: hetzner reachable, dial probe returns
  bytes, sync log clean bidirectional cycles, no fresh `unknown peer`.
- **launchd label changed:** the service is now `com.compoundingtech.fabric`
  (was `com.myobie.fabric`, org rename). The stale `com.myobie.fabric` job was
  booted out and its plist moved aside to `*.stale-501`. Use the new label.
- **Holds LIFTED:** default-home `fabric add`/`remove` and `fabric restart` are
  safe again — the daemon reads the same `~/.config/fabric/peers.toml` as the CLI.

## What fabric is

A standalone Rust CLI + local daemon that hides iroh behind local Unix sockets.
Consumer tools ask fabric for a local socket wired to a trusted remote peer and
speak their own protocol over it; only fabric touches iroh/QUIC/relays/NodeAddr
and the peer allow-list. See `README.md` and `SKILL.md`.

## In flight — `fabric sync` (generic file-sync primitive)

fabric now owns file sync. A config file (`syncs.toml`) lists sync entries; the
running daemon watches each folder and keeps it converged with its peers.

Status:
**Fully landed + pushed to origin main (fabric 0.2.0):** the config surface
(`syncs.toml`) and the property-tested reconciliation core
(`src/sync/{config,manifest,node,glob}`), the on-wire backend
(`src/sync/wire.rs`), the async `SyncEngine` (`src/sync/engine.rs`, fs-watch +
scan/materialize), the daemon wiring (`fabric/sync/1` ALPN, `IrohSyncTransport`,
engine started at boot, `SyncReload`/`SyncStatus` control ops), and the
`fabric sync add/ls/rm/reload` CLI. Proven end-to-end over real iroh by
`tests/sync_slice.rs`. All tests green; CLI smoke-tested; zero warnings.

Design decisions (why, so they are not re-litigated):
- **Backend-agnostic semantics.** The merge/conflict/delete/echo/convergence
  rules live in fabric (`sync::manifest` + `sync::node`), above a swappable
  transport. `Manifest::merge` is a semilattice join (commutative/associative/
  idempotent) → convergence and echo-freedom are structural, proven by property
  tests. Newer-wins = Lamport version + deterministic author tie-break (never a
  wall clock). The on-wire backend is verified to reach the exact same state as
  the pure reference reconcile — that is the swappable-backend guarantee.
- **Policies.** `catalog` = union + newer-wins + never-delete-on-peer + no-sweep
  (a local delete is restored; decommission is an edit, e.g. `retired = true`).
  `bus` = + tombstone deletes (modelled; sweep TTL not yet wired).
- **Config.** `~/.config/fabric/syncs.toml`, hand-editable, `fabric sync reload`
  applies live (mirrors `peers.toml` / `reload-peers`). Entry =
  `{name, folder, peers, policy, include?}`. `name` is the shared logical key
  (same name on two boxes = same sync); `peers = "*"` follows the `peers.toml`
  allow-list.

## Next

0. **ROAMING GAP — the shareability blocker (NEW top priority, Nathan 2026-07-22).**
   A peer that changes network/public IP goes unreachable both ways until its
   daemon is manually restarted. Root cause: fabric only reacts to LOCAL netmon
   changes (`run_network_rehome_loop`, `daemon.rs:1596`) and never actively probes
   peer reachability (the health poll skips the peer echo — `peer_probe_attempted=false`).
   Fix: promote a peer-liveness echo probe to always-on and drive the existing
   recovery ladder (drop tunnels → `network_change()` → recycle) on peer-probe
   failure. Same change gives continuous latency/direct-vs-relay telemetry (pathwatch,
   currently gated off via `FABRIC_PATHWATCH_SECS`). Full analysis + reliability
   data + nix-fabric design: `docs/multi-machine-reliability-2026-07-22.md`.
   Ready to implement on CoS/Nathan go.

1. **Fleet redeploy before the hetz proof** (CoS-coordinated). The *installed*
   fabric binaries are stale/pre-sync (`~/.local/bin/fabric` was 0.1.7+940afd1).
   A machine only serves/dials sync after its running daemon is **restarted**
   onto the 0.2.0 binary — a fresh file on disk is not enough. fabric-claude owns
   build + `./install.sh` + `fabric restart`; the Mac daemon restart blips the
   live network so the CoS sequences the window; the CoS drives the hetz
   pull+build+restart.
2. Run the **real hetz proof** (Mac → Hetzner): convoy declares the catalog on
   both (per-network name `convoy-catalog-<network>`), drop a `host=hetz` job in
   the Mac catalog, it appears on hetz, hetz's `convoy up` launches it. This is
   the done-bar.
3. Evaluate **iroh-docs 0.101.0** (iroh `^1`, range-based set reconciliation,
   LWW, iroh-blobs content) as backend #2 and green the SAME conformance suite
   against it. If healthy it likely becomes the production backend; `fast_rsync`
   stays a large-file delta optimization only.

## Open items / known gaps

- `bus` tombstone-sweep TTL is not implemented yet (deletes propagate; sweep is a
  no-op). Fine — bus is a later consumer (smalltalk).
- mtime is carried in the manifest but not restored to disk (ordering is logical,
  not mtime; disk mtime preservation is a future nicety).
- Changing an existing entry's `folder` needs a daemon restart to re-point its
  watcher; add/remove of entries is picked up live by `fabric sync reload`.
- The folder scan uses blocking `std::fs` on the async task; fine for small
  catalogs, revisit (spawn_blocking) if large trees appear.

## Coordination

- **convoy-claude** is the first consumer (its network catalog), wire-ready and
  standing by for the "green on main" ping.
- **cos-claude** is the supervisor; direct-on-main landing, push to origin.
