# Path Quality Reconnect Roadmap

Status: captured. This is the next reliability gap after RSS-triggered endpoint
recycle and allocator trimming.

## Live Repro

Source: `/tmp/cos-fabric-watchdog.log`, reported 2026-07-17 23:29 CEST.

Observed behavior:

- `fabric ping hetzner` held a direct path with roughly 5 second RTT for more
  than 30 minutes.
- Both daemons were otherwise healthy:
  - Mac: roughly 5 percent CPU and 98 MiB RSS.
  - Hetzner: roughly 2 percent CPU, 180 MiB RSS, and idle load around 0.06.
- Adjacent reachability checks were healthy:
  - ICMP Mac to Hetzner public IP: 18 ms, 0 percent packet loss.
  - ICMP Mac to Hetzner Tailscale IP: 18 ms, 0 percent packet loss.
  - Tailscale ping: 18 ms.
- A fabric restart recovered service, but only to roughly 46 ms over relay. It
  did not immediately establish a fresh direct iroh path.

This is a degraded-but-connected path. It is not a dead endpoint, not a memory
threshold breach, and not a host network outage.

The ICMP data does not prove that iroh's UDP hole-punched direct flow could have
achieved 18 ms. The direct UDP flow may have degraded for causes ICMP would not
show, such as stale NAT state, UDP rate limiting, or an asymmetric UDP path. The
precise claim is that iroh's direct flow went bad, iroh did not detect or
reselect away from that bad path, and restart fell back to a usable relay path.

## Current Blind Spot

Current in-process recovery paths cover:

- Debounced network-change events, followed by `endpoint.network_change()` and a
  health check.
- Periodic endpoint health checks that recycle when `Endpoint::online()` does
  not recover.
- RSS threshold recycle plus allocator trim on Linux.

Those signals miss a path that remains connected but becomes unusably slow. In
the repro, direct-path RTT ballooned while `Endpoint::online()` remained true
and daemon CPU/RSS stayed normal.

## Proposed Trigger

Add a per-peer path-quality monitor that reuses the built-in echo ping path.

Suggested shape:

- Poll trusted peers periodically with the existing echo ping implementation.
- Track a rolling RTT baseline per peer and per observed transport class
  (`direct`, `relay`, or `mixed`) when iroh exposes it.
- Mark a peer degraded only after consecutive successful pings exceed both:
  - a multiplier over baseline, such as 4x or 8x, and
  - an absolute floor, such as 500 ms or 1000 ms.
- Ignore the first samples after endpoint generation changes so cold-path
  setup and relay/direct warmup do not look like degradation.
- Require multiple consecutive degraded samples before recycling, so normal
  one-cycle jitter does not flap the endpoint.
- Recycle through the existing endpoint recycle path with reason
  `path quality degraded`, preserving the current recycle rate limit.

The first slice should prefer correctness over aggressiveness. A functional
relay path at 40-150 ms is acceptable; a persistent 5 second iroh path is not,
even when the process is otherwise healthy and non-iroh reachability checks look
good.

## Validation

Unit-level acceptance:

- A classifier test keeps a stable baseline during normal 40-150 ms jitter.
- A classifier test marks 5 second RTT as degraded after the configured
  consecutive sample count.
- A generation-change test resets or suppresses degradation state.
- A rate-limit test ensures one degraded peer cannot cause a recycle storm.

Integration-level acceptance:

- A fake ping sampler can drive the monitor without live WAN dependencies and
  assert that `recycle_endpoint_if_generation` is requested after persistent
  latency degradation.
- A future WAN eval should assert that a degraded-but-connected path
  self-recovers without manual process restart.

## Non-Goals

- Do not try to force iroh to use direct paths. Select the path that is actually
  healthy, even if that is relay.
- Do not replace network-change or RSS recovery. This is an additional trigger.
- Do not make service supervision responsible for this class. A managed service
  can restart crashes, but this failure happened inside a healthy process.
