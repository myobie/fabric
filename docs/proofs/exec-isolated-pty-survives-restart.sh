#!/usr/bin/env bash
# Proof: `fabric exec` can launch a backgrounded, ISOLATED process (its own
# cgroup, via a systemd scope/transient-unit wrapper) that SURVIVES the fabric
# service restarting — while a plain exec child, which lives in the fabric
# daemon's own cgroup, correctly dies with it.
#
# fabric exec is the ephemeral TRIGGER; wrap the payload in its own scope and it
# outlives the trigger. This is the shared mechanism behind an isolated-task-spawn
# primitive.
#
# Runs entirely on a Linux+systemd host against an ISOLATED dev fabric daemon
# (a transient user service with the SAME KillMode=control-group as production),
# so nothing production restarts. Self-cleans on exit.
set -u

FAB="$HOME/.local/bin/fabric"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"  # for systemctl --user
TMP="$(mktemp -d /tmp/fab-exec-proof.XXXXXX)"
A="$TMP/a"; B="$TMP/b"; mkdir -p "$A" "$B"
SERVER_UNIT="fab-exec-proof-server"     # the dev fabric daemon (fabric's cgroup)
PERSIST_UNIT="fab-exec-proof-payload"   # the scope-wrapped survivor (own cgroup)

say() { printf '\n=== %s ===\n' "$*"; }
cleanup() {
  systemctl --user stop "$PERSIST_UNIT.service" 2>/dev/null
  systemctl --user stop "$SERVER_UNIT.service" 2>/dev/null
  "$FAB" --home "$A" down 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_for_sock() { for _ in $(seq 1 50); do [ -S "$1/run/control.sock" ] && return 0; sleep 0.2; done; return 1; }

say "1. client A: plain fabric daemon"
"$FAB" --home "$A" up >/dev/null 2>&1
wait_for_sock "$A" || { echo "client A did not come up"; exit 1; }

say "2. server B: fabric daemon under a systemd user service (KillMode=control-group, --allow-exec)"
# A restart of THIS service SIGTERMs its whole cgroup — the exact behavior that
# makes a plain exec child ephemeral.
systemctl --user reset-failed "$SERVER_UNIT.service" 2>/dev/null
systemd-run --user --unit="$SERVER_UNIT" --property=KillMode=control-group --collect \
  -- "$FAB" --home "$B" up --foreground --allow-exec >/dev/null 2>&1
wait_for_sock "$B" || { echo "server B did not come up"; systemctl --user status "$SERVER_UNIT.service" --no-pager | tail; exit 1; }

say "3. cross-trust A <-> B, confirm exec works"
Bid="$("$FAB" --home "$B" id)"; Aid="$("$FAB" --home "$A" id)"
"$FAB" --home "$A" add "$Bid" b --addr-json "$("$FAB" --home "$B" addr)" >/dev/null
"$FAB" --home "$A" reload-peers >/dev/null
"$FAB" --home "$B" add "$Aid" a --addr-json "$("$FAB" --home "$A" addr)" >/dev/null
"$FAB" --home "$B" reload-peers >/dev/null
echo "exec sanity: $("$FAB" --home "$A" exec b -- /bin/echo exec-works)"

say "4. EPHEMERAL launch via fabric exec (plain backgrounded process -> lands in B's cgroup)"
"$FAB" --home "$A" exec b -- /bin/bash -c \
  "setsid /bin/bash -c 'while :; do sleep 1; done' >/dev/null 2>&1 & echo \$! > $TMP/eph.pid"
EPH_PID="$(cat "$TMP/eph.pid")"
echo "ephemeral pid=$EPH_PID"
echo "ephemeral cgroup: $(tr -d '\0' < /proc/$EPH_PID/cgroup 2>/dev/null | tail -1)"

say "5. PERSISTENT launch via fabric exec (systemd-run scope wrapper -> OWN cgroup)"
"$FAB" --home "$A" exec b -- systemd-run --user --unit="$PERSIST_UNIT" --collect \
  -- /bin/bash -c 'while :; do sleep 1; done'
sleep 1
PERSIST_PID="$(systemctl --user show -p MainPID --value "$PERSIST_UNIT.service")"
echo "persistent unit active(before)=$(systemctl --user is-active "$PERSIST_UNIT.service") pid=$PERSIST_PID"
echo "persistent cgroup: $(tr -d '\0' < /proc/$PERSIST_PID/cgroup 2>/dev/null | tail -1)"

say "6. RESTART the fabric server service (SIGTERMs its cgroup)"
systemctl --user restart "$SERVER_UNIT.service"
wait_for_sock "$B" || echo "(server B did not fully come back — fine for the assertion)"
sleep 2

say "7. ASSERT"
if kill -0 "$EPH_PID" 2>/dev/null; then EPH="ALIVE"; else EPH="DEAD"; fi
PERSIST_AFTER="$(systemctl --user is-active "$PERSIST_UNIT.service")"
echo "ephemeral child after restart : $EPH   (expect DEAD — it shared fabric's cgroup)"
echo "persistent child after restart: $PERSIST_AFTER   (expect active — own scope cgroup)"
if [ "$EPH" = "DEAD" ] && [ "$PERSIST_AFTER" = "active" ]; then
  echo; echo "PROOF: PASS — fabric exec launched an isolated payload that survived the fabric service restart, while a plain exec child died with it."
  exit 0
else
  echo; echo "PROOF: FAIL"
  exit 1
fi
