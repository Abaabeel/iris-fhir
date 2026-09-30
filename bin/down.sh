#!/usr/bin/env bash
# Stop the stack, in reverse dependency order.
#
#   bin/down.sh           stop all five services
#   bin/down.sh --purge   also delete PAS's H2 files and DTR's lowdb store
#
# --purge exists because PAS and DTR keep state on disk between runs. Without
# it a half-finished demo leaves Claims and client registrations behind, and the
# next run inherits them (PLAN.md §6 Phase 4).
set -uo pipefail
source "$(dirname "$0")/env.sh"

LOGDIR="$DAVINCI_ROOT/logs"
PIDDIR="$DAVINCI_ROOT/pids"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }

stop_svc() {
  local name="$1" pidfile="$PIDDIR/$1.pid" pid
  [ -f "$pidfile" ] || { warn "$name: no pid file"; return 0; }
  pid="$(cat "$pidfile")"
  if ! kill -0 "$pid" 2>/dev/null; then
    warn "$name: not running (stale pid $pid)"
    rm -f "$pidfile"
    return 0
  fi
  # Negative pid: kill the whole process group. up.sh uses setsid, so this
  # takes the Gradle/Maven wrapper and its daemon with it. Plain `kill $pid`
  # leaves JVMs and webpack children alive holding the ports.
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  for _ in {1..20}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "$name: did not exit on SIGTERM, sending SIGKILL"
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  fi
  rm -f "$pidfile"
  ok "$name stopped"
}

# Reverse of the up.sh order.
for svc in crd-request-generator dtr prior-auth crd ehr-shim test-ehr; do
  stop_svc "$svc"
done

# A recorded PID is not necessarily the process holding the port:
#   - `mvn spring-boot:run` is a shell script that execs a SEPARATE JVM, so the
#     JVM survives its parent.
#   - Gradle's `bootRun` runs inside a daemon-launched process tree.
# Killing the recorded process group therefore reports "stopped" while all five
# ports stay bound. The ports are the contract, so sweep them.
#
# Safety: only ever kill a listener that belongs to this project. Two signals,
# because neither alone is enough:
#   - the command line, which for the JVMs carries the full classpath under
#     $DAVINCI_ROOT, but for Node is just `node ./bin/prod` (relative paths);
#   - the working directory, read from /proc/<pid>/cwd, which is the repo dir.
# The unrelated Next.js app on :3000 shares this box and must not be touched.
sweep_ports() {
  local pids p cmdline cwd
  pids="$(ss -tlnp 2>/dev/null \
    | grep -E ":$STACK_PORTS_RE\b" \
    | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
  [ -z "$pids" ] && return 0
  for p in $pids; do
    cmdline="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
    cwd="$(readlink -f "/proc/$p/cwd" 2>/dev/null)"
    # KEYCLOAK_HOME is a second root on purpose: keycloak is installed on ext4
    # (/opt) because it can sit on a different volume, so a test keyed only on $DAVINCI_ROOT
    # classifies it as "not ours", leaves :8180 bound, and the next up.sh then
    # trips its own stale-port guard -- or worse, probes green off the zombie.
    case "$cmdline$cwd" in
      *"$DAVINCI_ROOT"*|*"$KEYCLOAK_HOME"*)
        warn "stray listener pid $p on a stack port — killing"
        kill -KILL "$p" 2>/dev/null ;;
      *)
        warn "pid $p holds a stack port but is NOT ours — leaving it alone:"
        warn "    cmd: ${cmdline:-?}"
        warn "    cwd: ${cwd:-?}" ;;
    esac
  done
  # SIGKILL is unblockable, but on this 9p mount a dying JVM can sit in an
  # uninterruptible write for a while, and a socket in TIME_WAIT-less LISTEN
  # state can outlive it. One pass plus sleep 2 was not enough in practice, so
  # keep re-sweeping until the ports are genuinely free or we give up.
  local waited=0
  while [ "$waited" -lt 30 ]; do
    sleep 2; waited=$((waited+2))
    [ -z "$(ss -tlnp 2>/dev/null | grep -E ":$STACK_PORTS_RE\b")" ] && return 0
    pids="$(ss -tlnp 2>/dev/null | grep -E ":$STACK_PORTS_RE\b" \
      | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
    for p in $pids; do
      cmdline="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
      cwd="$(readlink -f "/proc/$p/cwd" 2>/dev/null)"
      # same two roots as the first pass -- see the note there
      case "$cmdline$cwd" in
        *"$DAVINCI_ROOT"*|*"$KEYCLOAK_HOME"*) kill -KILL "$p" 2>/dev/null ;;
      esac
    done
  done
  return 1
}

if ss -tlnp 2>/dev/null | grep -qE ':(8080|8090|3005|3001|9015)\b'; then
  say "sweeping stack ports (forked children outlived their parents)"
  sweep_ports
fi

# Gradle leaves daemons behind that hold no ports but do hold memory, and this
# box has ~6 GB for five services. Only the ones pointed at our GRADLE_USER_HOME.
if [ -d "$GRADLE_USER_HOME" ]; then
  pkill -f "GradleDaemon.*$GRADLE_USER_HOME" 2>/dev/null && \
    ok "gradle daemons stopped" || true
fi

if [ "$PURGE" = 1 ]; then
  say "purging on-disk state"
  rm -rf "$PAS_DIR/databaseData"        # PAS: file-backed H2, Claims + Rules + Audit
  rm -rf "$DTR_DIR/databaseData"        # DTR: lowdb client registrations
  ok "PAS H2 and DTR lowdb removed"
  warn "test-ehr and CRD use in-memory H2 (jdbc:h2:mem:test_mem) — nothing to purge;"
  warn "they re-seed from seed-data on every boot."
fi

say "remaining listeners on stack ports:"
ss -tlnp 2>/dev/null | grep -E ":$STACK_PORTS_RE\b" || echo "  none"
