# now — fabric working state

The living handoff for whoever owns fabric next (there was none before; keep this
current). This records what is DONE, what is IN FLIGHT, and what is NEXT — the
things the repo history alone does not carry.

_Last updated: 2026-07-21 by fabric-claude (opus). fabric 0.2.0 on origin main._

## Hotfix STAGED — peer-config split (awaiting the restart window)

On 2026-07-21 the Mac↔hetz stopgap sync (rsync over `fabric dial`) failed in a
loop and blocked cos from reaching the hetz fleet. Root cause: the launchd
service launches the daemon as `--home ~/.local/share/fabric`, which (pre-fix)
made the dial path read `peers.toml` from under `--home` while the CLI writes
`~/.config/fabric/peers.toml`; a default-home `fabric add` migrated + deleted the
in-`--home` copy, leaving the daemon with zero peers on the dial path
(`unknown peer` in `service.err.log`) while `ping`/`status`/`shell` kept working.

- **Live link:** RESTORED (stopgap = write hetzner into the daemon-home
  `peers.toml`; survives restarts as long as it is not re-deleted).
- **Durable fix:** landed on main — `FabricHome::resolve` now treats an explicit
  `--home` equal to the default state root like the no-arg default (peers from
  `~/.config/fabric/`). Unit-tested; binary installed to `~/.local/bin/fabric`.
- **NOT yet active:** the running daemon still uses the OLD binary. cos sequences
  the restart window with Nathan, likely folded into the fabric-sync redeploy.
  Safe swap: install (done) → verify peers resolve under `--home` → bootstrap the
  `com.myobie.fabric` launchd service (currently unmanaged — no KeepAlive).
- **Until the swap:** do NOT run a default-home `fabric add`/`remove` (re-splits
  peers), and do NOT `fabric restart`/bootstrap on the old binary (re-lockout).

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
