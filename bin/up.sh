#!/usr/bin/env bash
# Bring up the 5-service DaVinci prior-auth mock, natively, in dependency order.
#
#   bin/up.sh            start everything, poll real readiness endpoints
#   bin/up.sh --reset    same, but wipe PAS H2 + DTR lowdb state first
#
# Deliberately five independent process groups, not one supervisor process: a
# crash in one must not kill-loop the rest, and each needs its own readiness
# signal (PLAN.md §2).
set -uo pipefail
source "$(dirname "$0")/env.sh"

LOGDIR="$DAVINCI_ROOT/logs"
PIDDIR="$DAVINCI_ROOT/pids"
mkdir -p "$LOGDIR" "$PIDDIR"

RESET=0
[ "${1:-}" = "--reset" ] && RESET=1

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m FAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m ERR\033[0m %s\n' "$*" >&2; exit 1; }

# --- readiness: poll a real endpoint, not a liveness signal that always lies ---
# CRD's /actuator/health reports a permanent DOWN (fix #4) and its /metadata is
# a 404 because CRD is a CDS Hooks server, not a FHIR server. PAS has no
# actuator at all. So each probe below is the endpoint that actually answers.
wait_http() {
  local url="$1" timeout="${2:-180}" label="$3" i
  for ((i = 0; i < timeout; i++)); do
    if curl -fsS -m 3 -o /dev/null "$url" 2>/dev/null; then
      ok "$label ready (${i}s)  $url"
      return 0
    fi
    sleep 1
  done
  warn "$label NOT ready after ${timeout}s  $url  (see $LOGDIR/$label.log)"
  return 1
}

# launch <name> <workdir> <probe-url> <env-assignments...> -- <cmd...>
launch() {
  local name="$1" dir="$2" probe="$3"; shift 3
  local envs=() cmd=()
  # $# guard: a `#` comment sitting inside a backslash-continued argument list
  # swallows the `--` separator, the loop then runs off the end of "$@", and
  # under `set -u` the only symptom is a bare "$1: unbound variable" that names
  # neither the service nor the line that caused it.
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] || { bad "launch $name: no '--' separator before the command"; return 1; }
  shift
  cmd=("$@")

  if [ -f "$PIDDIR/$name.pid" ] && kill -0 "$(cat "$PIDDIR/$name.pid")" 2>/dev/null; then
    warn "$name already running (pid $(cat "$PIDDIR/$name.pid"))"
    return 0
  fi

  say "starting $name  ->  $probe"
  # setsid: own process group, so down.sh can kill the whole tree with one
  # signal. Gradle in particular spawns a daemon that must not outlive us.
  ( cd "$dir" && setsid env "${envs[@]}" "${cmd[@]}" \
      >"$LOGDIR/$name.log" 2>&1 < /dev/null & echo $! > "$PIDDIR/$name.pid" )
  wait_http "$probe" "${READY_TIMEOUT:-300}" "$name" || true
}

port_holders() {
  ss -tlnp 2>/dev/null | grep -E ":$STACK_PORTS_RE\b" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

# Refuse to start on a port someone else already owns.
#
# This is not paranoia. It happened: a PAS JVM from a previous run outlived
# down.sh, kept :9015, and held the H2 file. The new PAS could neither bind the
# port nor open its database -- and up.sh still printed "prior-auth ready",
# because the readiness probe was answered by the ZOMBIE. A green table, a
# broken service, and a stack that looks fine until you query a table.
require_ports_free() {
  local waited=0 holders
  holders="$(port_holders)"
  [ -z "$holders" ] && return 0
  say "stack ports still held, waiting for them to clear (up to ${PORT_WAIT}s)"
  while [ "$waited" -lt "$PORT_WAIT" ] && [ -n "$(port_holders)" ]; do
    sleep 2; waited=$((waited+2))
  done
  holders="$(port_holders)"
  [ -z "$holders" ] && { ok "ports cleared after ${waited}s"; return 0; }
  for p in $holders; do
    bad "port still held after ${waited}s: pid $p"
    warn "    cmd: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-90)"
    warn "    cwd: $(readlink -f "/proc/$p/cwd" 2>/dev/null)"
  done
  die "refusing to start: a stale process owns a stack port.
     Kill the pids above (or run bin/down.sh again) and retry.
     Starting anyway is what produces a stack that probes green but is
     wired to the wrong process."
}
require_ports_free

if [ "$RESET" = 1 ]; then
  say "reset: clearing PAS H2 + DTR lowdb state"
  rm -rf "$PAS_DIR/databaseData"
  # Delete the directory but recreate it immediately. dtr's lowdb writes to
  # databaseData/.db.json.tmp and does NOT create the directory, so removing it
  # outright leaves dtr unable to register its client ever again — and the
  # symptom is a healthy-looking 200 on / with an EMPTY /clients, i.e. a dead
  # SMART link at demo time. The dir is normally guaranteed by the tracked
  # databaseData/.gitkeep, which is exactly what a blind rm -rf destroys.
  rm -rf "$DTR_DIR/databaseData"
  mkdir -p "$DTR_DIR/databaseData"
  ok "state cleared"
fi

# --- 0. one-time frontend builds -------------------------------------------
# Both Node services serve a PREBUILT bundle in production mode. Build once,
# then reuse: these are the slow steps and nothing about them changes between
# demo runs.
if [ ! -d "$DTR_DIR/public/js" ] || [ -z "$(ls -A "$DTR_DIR/public/js" 2>/dev/null)" ]; then
  say "building dtr frontend (one-time, this is the slow one)"
  # 1280m, not NODE_XMX: the webpack build needs far more headroom than the
  # server does. At 256m it dies with "Reached heap limit ... JavaScript heap
  # out of memory" and dumps core.
  ( cd "$DTR_DIR" && NODE_OPTIONS="--max-old-space-size=${DTR_BUILD_XMX:-1280}" npm run buildFrontendProd \
      >"$LOGDIR/build-dtr.log" 2>&1 ) || die "dtr frontend build failed, see $LOGDIR/build-dtr.log"
  ok "dtr frontend built"
fi
if [ ! -f "$CRG_DIR/build/index.html" ]; then
  say "building crd-request-generator frontend (one-time)"
  ( cd "$CRG_DIR" && NODE_OPTIONS="--max-old-space-size=${DTR_BUILD_XMX:-1280}" npm run build \
      >"$LOGDIR/build-crg.log" 2>&1 ) || die "crg build failed, see $LOGDIR/build-crg.log"
  ok "crg frontend built"
fi

# --- 0. keycloak : the auth server the DTR SMART hop redirects into -------
# The dtr browser hop is a three-party OAuth dance: crg -> test-ehr /auth
# (proxy) -> Keycloak authorize -> login -> test-ehr /token -> dtr. The proxy
# is unconditional — `use_oauth: false` in test-ehr's application.yaml does NOT
# skip it, which is why the hop failed against an empty :8180 even though the
# rest of the stack was green.
#
# JAVA_HOME is overridden to the system JDK 21: env.sh pins the project's JDK 17
# for the Maven/Gradle services, and kc.sh runs "$JAVA_HOME/bin/java", so without
# this it would start on 17 and refuse.
if [ ! -x "$KEYCLOAK_HOME/bin/kc.sh" ]; then
  die "keycloak not found at $KEYCLOAK_HOME (see TEST-FLOW.md §12 for install)"
fi
KC_JAVA_HOME="${KEYCLOAK_JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
[ -x "$KC_JAVA_HOME/bin/java" ] || die "need a JDK 21 for keycloak; $KC_JAVA_HOME has no bin/java"
# Realm import is only read when the realm is absent, so re-copying is a no-op
# after the first boot. Keeping the source of truth in fixtures/ means a wiped
# /opt/keycloak/data can be rebuilt without hunting for a JSON that lived only
# in the container.
mkdir -p "$KEYCLOAK_HOME/data/import"
cp -f "$DAVINCI_ROOT/fixtures/keycloak/BurdenReduction-realm.json" \
      "$KEYCLOAK_HOME/data/import/BurdenReduction-realm.json"
# hostname-strict is off: the browser may arrive as localhost:8180 (WSL or Windows) or
# as <lan-ip>:8180, and strict mode would pin the issuer/token URLs to whichever
# hostname won the race, breaking the other. sslRequired=none in the realm export
# is what actually allows plain http.
launch keycloak "$KEYCLOAK_HOME" \
  "http://localhost:$KEYCLOAK_PORT/realms/BurdenReduction/.well-known/openid-configuration" \
  JAVA_HOME="$KC_JAVA_HOME" \
  KC_BOOTSTRAP_ADMIN_USERNAME="$KEYCLOAK_ADMIN_USER" \
  KC_BOOTSTRAP_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASS" \
  KC_HTTP_ENABLED=true \
  KC_HTTP_PORT="$KEYCLOAK_PORT" \
  KC_HOSTNAME_STRICT=false \
  KC_HOSTNAME_STRICT_HTTPS=false \
  -- ./bin/kc.sh start-dev --import-realm

# --- 1. ehr-shim : IRIS for Health FHIR, fronted on 8080 -------------------
# Replaces test-ehr. The real FHIR server is IRIS in the iris-fhir LXC
# container (10.0.3.108:52774/fhir/r4); this Node shim replicates test-ehr's
# SMART launch + OAuth bridge on the same port, so nothing else in the stack
# changes — crg/dtr still see http://localhost:8080/fhir/r4. The container is
# provisioned and seeded out of band (bin/seed-iris.sh); this step only needs
# it to be reachable at $IRIS_FHIR_BASE.
launch ehr-shim "$DAVINCI_ROOT/bin/ehr-shim" "http://localhost:$TEST_EHR_PORT/fhir/r4/metadata" \
  SHIM_PORT="$TEST_EHR_PORT" \
  IRIS_FHIR_BASE="$IRIS_FHIR_BASE" \
  IRIS_OAUTH_TOKEN="$IRIS_TOKEN_URL" \
  IRIS_OAUTH_CLIENT_ID="$IRIS_OAUTH_CLIENT_ID" \
  IRIS_OAUTH_CLIENT_SECRET="$IRIS_OAUTH_CLIENT_SECRET" \
  IRIS_OAUTH_SCOPES="$IRIS_OAUTH_SCOPES" \
  KC_AUTHORIZE="http://$ADVERTISE_HOST:$KEYCLOAK_PORT/realms/BurdenReduction/protocol/openid-connect/auth" \
  KC_TOKEN="http://$ADVERTISE_HOST:$KEYCLOAK_PORT/realms/BurdenReduction/protocol/openid-connect/token" \
  -- node server.js

# --- 2. crd : CDS Hooks, turns orders into coverage-requirements cards ------
# Seeded before crd boots, because crd reads the cache at startup and an empty
# cache means every questionnaire render 500s on "Is the VSAC_API_KEY set?".
"$DAVINCI_ROOT/bin/seed-valuesets.sh" >"$LOGDIR/seed-valuesets.log" 2>&1 \
  || warn "value-set seeding incomplete, see $LOGDIR/seed-valuesets.log (dtr questionnaires may 500)"
launch crd "$CRD_DIR" "http://localhost:$CRD_PORT/r4/cds-services" \
  MANAGEMENT_HEALTH_ELASTICSEARCH_ENABLED=false \
  CORS_ORIGINS="$CORS_ORIGINS" \
  VALUESETCACHEPATH="$VSAC_CACHE_DIR" \
  -- ./gradlew -Dorg.gradle.jvmargs="-Xmx$CRD_XMX" server:bootRun

# --- 3. pas : the payer side, returns the ClaimResponse --------------------
launch prior-auth "$PAS_DIR" "http://localhost:$PAS_PORT/fhir/metadata" \
  debug=true BYPASS_AUTH=true DELAY="$DELAY" \
  TOKEN_BASE_URI="http://localhost:$PAS_PORT" \
  -- ./gradlew -Dorg.gradle.jvmargs="-Xmx$PAS_XMX" bootRun

# --- 4. dtr : the SMART app the card links into ---------------------------
# The dir must exist before launch: dtr registers its client into it on boot
# and lowdb will not create it. `mkdir -p` is idempotent and costs nothing.
mkdir -p "$DTR_DIR/databaseData"
launch dtr "$DTR_DIR" "http://localhost:$DTR_PORT/" \
  NODE_OPTIONS="--max-old-space-size=$NODE_XMX" \
  REACT_APP_SERVER_PORT="$DTR_PORT" \
  REACT_APP_INITIAL_CLIENT="$REACT_APP_INITIAL_CLIENT" \
  -- node ./bin/prod

# --- 5. crd-request-generator : the UI that drives the demo ----------------
# The REACT_APP_* vars are passed in explicitly on purpose. crg's server.js serves
# /env-config straight from process.env and DROPS any key that is null, at which
# point the UI silently falls back to the localhost values baked into the webpack
# bundle at build time. That fallback is invisible: the app loads, the patient
# list works when the browser happens to be on this host, and only a remote
# browser discovers that every call is aimed at its own localhost.
launch crd-request-generator "$CRG_DIR" "http://localhost:$CRG_PORT/" \
  NODE_ENV=production PORT="$CRG_PORT" \
  REACT_APP_EHR_SERVER="$REACT_APP_EHR_SERVER" \
  REACT_APP_CDS_SERVICE="$REACT_APP_CDS_SERVICE" \
  REACT_APP_ORDER_SELECT="$REACT_APP_ORDER_SELECT" \
  REACT_APP_ORDER_SIGN="$REACT_APP_ORDER_SIGN" \
  REACT_APP_LAUNCH_URL="$REACT_APP_LAUNCH_URL" \
  REACT_APP_PUBLIC_KEYS="$REACT_APP_PUBLIC_KEYS" \
  REACT_APP_CLIENT="$REACT_APP_CLIENT" \
  -- node server.js

# --- status table ----------------------------------------------------------
printf '\n\033[1m%-24s %-6s %-34s %s\033[0m\n' SERVICE PORT PROBE STATE
printf '%-24s %-6s %-34s %s\n' ---------------------------- ------ ------------------ ------
while read -r name port probe; do
  if curl -fsS -m 3 -o /dev/null "$probe" 2>/dev/null; then state=$'\033[1;32mUP\033[0m'
  else state=$'\033[1;31mDOWN\033[0m'; fi
  printf '%-24s %-6s %-34s %b\n' "$name" "$port" "$probe" "$state"
done <<EOF
keycloak            $KEYCLOAK_PORT  http://localhost:$KEYCLOAK_PORT/realms/BurdenReduction/.well-known/openid-configuration
ehr-shim            $TEST_EHR_PORT  http://localhost:$TEST_EHR_PORT/fhir/r4/metadata
crd                 $CRD_PORT       http://localhost:$CRD_PORT/r4/cds-services
prior-auth          $PAS_PORT       http://localhost:$PAS_PORT/fhir/metadata
dtr                 $DTR_PORT       http://localhost:$DTR_PORT/
crd-request-generator $CRG_PORT     http://localhost:$CRG_PORT/
EOF

# --- post-flight: the failures that look like success ---------------------
# A green readiness table is not the same as a working stack. Each check below
# is a condition that a naive probe passes while the demo is actually broken.
say "post-flight checks (green readiness is not the same as a working stack)"

# 1. dtr registered its client (fix #13). Empty /clients with a 200 on / is the
#    single most likely visible demo failure: the card's SMART link dead-ends.
dtr_clients="$(curl -fsS -m 5 "http://localhost:$DTR_PORT/clients" 2>/dev/null || echo '[]')"
if [ "$(printf '%s' "$dtr_clients" | tr -d ' \n')" = "[]" ]; then
  warn "dtr /clients is EMPTY — the card's SMART link will dead-end."
  warn "  cause: $DTR_DIR/databaseData missing or unwritable, so the"
  warn "  REACT_APP_INITIAL_CLIENT self-PUT failed. Check $LOGDIR/dtr.log."
else
  ok "dtr client registered: $(printf '%s' "$dtr_clients" | tr -d '\n' | cut -c1-70)"
fi

# 2. CRD actually advertises the hook (not just that the port answers).
if curl -fsS -m 5 "http://localhost:$CRD_PORT/r4/cds-services" 2>/dev/null | grep -q 'order-sign-crd'; then
  # Test the path the way crd builds it, not the way we spelled it.
  if [ -r "${VSAC_CACHE_DIR}ValueSet-R4-2.16.840.1.113762.1.4.1219.35.json" ]; then
    ok "vsac cache reachable at crd's concatenated path"
  else
    bad "vsac cache NOT reachable at '${VSAC_CACHE_DIR}ValueSet-R4-...json'"
    warn "    crd concatenates valueSetCachePath + filename with no separator,"
    warn "    so VSAC_CACHE_DIR must end in a slash. dtr questionnaires will 500."
  fi
  ok "crd advertises order-sign-crd"
else
  warn "crd is up but not advertising order-sign-crd — the card will never appear"
fi

# 2b. Warm CRD's write-once "doc-needed" flag. CRD's hasDocNeededExtension()
#     caches its result on the CdsService singleton: the FIRST cds-services POST
#     after boot decides whether responses ever carry systemActions. A request
#     that yields the summary card -- e.g. the prefetch-less reprovision fixture,
#     which throws RequestIncompleteException -- caches "false", and every later
#     request silently drops systemActions: crg never renders the
#     "Complete ... in DTR" button and the browser E2E fails at the SMART launch.
#     Warming with a real prefetch-carrying request FIRST makes it cache "true".
#     The flag is write-once, so after this points everything downstream is safe
#     in any order.
crd_warm_code="$(curl -s -m 30 -o "$LOGDIR/crd-warmup.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-binary @"$DAVINCI_ROOT/fixtures/order-sign-warmup.json" \
  "http://localhost:$CRD_PORT/r4/cds-services/order-sign-crd")"
if [ "$crd_warm_code" = 200 ]; then
  crd_warm_actions="$(python3 -c "
import json
d = json.load(open('$LOGDIR/crd-warmup.json'))
print(len(d.get('systemActions') or []))
" 2>/dev/null || echo -1)"
  if [ "${crd_warm_actions:-0}" -gt 0 ]; then
    ok "crd doc-needed flag warmed (systemActions=$crd_warm_actions)"
  else
    bad "crd systemActions is EMPTY after the warmup -- doc-needed flag poisoned"
    warn "    An earlier request (e.g. the prefetch-less reprovision fixture) made"
    warn "    CRD's first cds-services scan cache 'false' for this boot, so no card"
    warn "    will ever carry questionnaires and the browser E2E cannot launch DTR."
    warn "    Restart CRD (kill its port-8090 process group) and re-run bin/up.sh"
    warn "    so this warmup is the first cds-services POST."
  fi
else
  warn "crd warmup returned $crd_warm_code (see $LOGDIR/crd.log)"
fi

# 3. PAS seeded itself. debug=true makes this automatic (fix #7/#8), so an
#    empty Rules table means the seeding did not happen.
rules_rows="$(curl -fsS -m 5 "http://localhost:$PAS_PORT/fhir/debug/Rules" 2>/dev/null | grep -c '<tr>')"
if [ "${rules_rows:-0}" -gt 1 ]; then
  ok "pas seeded itself ($((rules_rows - 1)) rules)"
else
  warn "pas Rules table looks empty — seeding did not run"
fi

printf '\nDemo: open http://%s:%s/  -> R4 -> patient pat013 -> E0607 -> Submit\n' "$ADVERTISE_HOST" "$CRG_PORT"
printf 'Or run the whole frozen path unattended:  bin/demo.sh\n'
printf 'Logs: %s/\n\n' "$LOGDIR"
