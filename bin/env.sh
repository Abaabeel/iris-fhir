#!/usr/bin/env bash
# Shared environment for the DaVinci prior-auth mock stack.
# Sourced by bin/up.sh, bin/down.sh and any ad-hoc shell.
#
#   source bin/env.sh
#
# Layout (all inside this folder, nothing in /tmp — /tmp does not survive here):
#   runtime/jdk17          Temurin JDK 17.0.20.1     (CRD + PAS + test-ehr)
#   runtime/maven          Apache Maven 3.9.9        (test-ehr ships no mvnw)
#   repos/<svc>            upstream checkouts at the SHAs pinned in PLAN.md §2
#   logs/ pids/ state/     per-service log, PID file and runtime state

# ${BASH_SOURCE[0]:-$0} rather than ${BASH_SOURCE[0]} alone: this file gets
# sourced from zsh as well as bash, and BASH_SOURCE is empty under zsh, which
# silently resolved DAVINCI_ROOT one directory too high.
DAVINCI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export DAVINCI_ROOT

# --- toolchain (non-invasive: nothing installed system-wide) ---
export JAVA_HOME="$DAVINCI_ROOT/runtime/jdk17"
export M2_HOME="$DAVINCI_ROOT/runtime/maven"
export PATH="$JAVA_HOME/bin:$M2_HOME/bin:$PATH"

# --- build caches deliberately NOT on this folder ---
# If this checkout lives on a network or virtualised filesystem (a 9p/DrvFs mount,
# NFS, a VM shared folder), small-file writes are one to two orders of magnitude
# slower than native ext4 -- measured at ~260x here, where 2000 files took 9.85 s
# against 0.04 s on ext4. Gradle and Maven write tens of thousands of small files,
# so their caches go on local disk instead. Both are overridable; set them here to
# relocate onto this folder if you prefer.
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/root/.cache/davinci-mock/gradle}"
export MAVEN_OPTS="${MAVEN_OPTS:--Xmx512m}"
mkdir -p "$GRADLE_USER_HOME"

# --- authoritative ports (from prior-auth/docker-compose.yml, see PLAN.md §2) ---
export TEST_EHR_PORT=8080     # ehr-shim -> IRIS (replaces test-ehr on this port)
export CRD_PORT=8090          # crd
export DTR_PORT=3005          # dtr
export CRG_PORT=3001          # crd-request-generator — NOT 3000, taken on this host (item 18)
export PAS_PORT=9015          # prior-auth
export KEYCLOAK_PORT=8180     # keycloak — realm BurdenReduction, required by the DTR hop

# --- IRIS for Health FHIR: the real EHR behind ehr-shim ----------------------
# The FHIR server runs in LXC container `iris-fhir` (10.0.3.108); bin/ehr-shim
# fronts it on $TEST_EHR_PORT and replicates test-ehr's SMART/OAuth surface.
# These are the local mock fixtures created when the container was provisioned
# (ConfigureInternalOAuthClients) — the same standing as Keycloak's admin/admin.
export IRIS_FHIR_BASE="${IRIS_FHIR_BASE:-https://10.0.3.108:52774/fhir/r4}"
export IRIS_TOKEN_URL="${IRIS_TOKEN_URL:-${IRIS_FHIR_BASE%/fhir/r4}/oauth2/token}"
export IRIS_OAUTH_CLIENT_ID="${IRIS_OAUTH_CLIENT_ID:-MvrcDCC1LRt-UIEE-cXVpxyHnKhLDGuyBfpHZMNtWrA}"
export IRIS_OAUTH_CLIENT_SECRET="${IRIS_OAUTH_CLIENT_SECRET:-I4CuQe1QbItnvt7FmpqyM6qN1d3IKwgsI37n7LmdU6eaLKb2rlJ9f_XA6yEXOMsutDyU_FvDSnsU6hdSg9HLhw}"
export IRIS_OAUTH_SCOPES="${IRIS_OAUTH_SCOPES:-user/*.write user/*.rs}"

# Keycloak lives OUTSIDE this folder, on local disk. The H2 data dir plus a
# ~190 MB unpacked distribution have no business landing on a slow or small
# filesystem, and re-cloning the repos would not restore it. Override if you want
# it elsewhere.
export KEYCLOAK_HOME="${KEYCLOAK_HOME:-/opt/keycloak}"
export KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
export KEYCLOAK_ADMIN_PASS="${KEYCLOAK_ADMIN_PASS:-admin}"
# The demo user the Keycloak login page expects (see fixtures/keycloak/*.json).
export KEYCLOAK_TEST_USER="${KEYCLOAK_TEST_USER:-dtr}"
export KEYCLOAK_TEST_PASS="${KEYCLOAK_TEST_PASS:-dtr-demo}"

# VSAC value-set cache. On ext4 for the same reason as keycloak: these are
# ~1.5 MB of derived terminology that would otherwise land in the cloned repo and
# be wiped by the next bin/clone.sh. Overrides crd's own valueSetCachePath
# (application.yml:84) via Spring relaxed binding.
export VSAC_CACHE_DIR="${VSAC_CACHE_DIR:-/root/.cache/davinci-mock/vsac-cache}"
# The trailing slash is load-bearing. Both file stores build the cache path by
# plain string concatenation -- CdsConnectFileStore.java:315 and
# LocalFileStore.java:171 both do getValueSetCachePath() + filename, with no
# separator. Upstream's default "ValueSetCache/" happens to end in a slash, so
# a tidy-looking override without one silently produces
#   /root/.cache/davinci-mock/vsac-cacheValueSet-R4-<oid>.json
# and every value set reads back as "not found" while the boot log cheerfully
# reports all of them added.
case "$VSAC_CACHE_DIR" in */) ;; *) VSAC_CACHE_DIR="$VSAC_CACHE_DIR/" ;; esac

# The six ports that make up the stack, derived so up.sh and down.sh can never
# drift apart. down.sh sweeps these; up.sh refuses to start while any is held.
export STACK_PORTS="$TEST_EHR_PORT|$CRD_PORT|$DTR_PORT|$CRG_PORT|$PAS_PORT|$KEYCLOAK_PORT"
export STACK_PORTS_RE="($(printf '%s' "$STACK_PORTS" | tr '|' '|'))"
# The host the UI should ADVERTISE to the browser. Everything binds 0.0.0.0, but
# binding is not the same as being usable: the browser is the thing that decides
# which host to call, and the UI is handed these URLs at runtime (crg serves
# /env-config from its own process env, and up.sh passes them through). So this
# value is what a remote browser will actually dial.
#
#   default          -> http://localhost:...  (WSL-internal and Windows-via-localhost)
#   ADVERTISE_HOST=<ip> bin/up.sh
#                    -> http://<ip>:...       (a real second machine on the LAN)
#
# It must stay consistent with REACT_APP_INITIAL_CLIENT below: the SMART `iss` the
# UI sends has to equal the client name DTR registered, or dtr's lookup finds
# neither the issuer nor a "default" entry and refuses to launch.
export ADVERTISE_HOST="${ADVERTISE_HOST:-localhost}"

# How long up.sh waits for a predecessor's port to clear before giving up.
export PORT_WAIT="${PORT_WAIT:-30}"

# --- per-JVM heap caps (PLAN.md §2; box has ~5-6 GB available of 7 GB) ---
export EHR_XMX=512m
export CRD_XMX=640m
export PAS_XMX=768m
export NODE_XMX=256

# --- repo roots ---
export EHR_DIR="$DAVINCI_ROOT/repos/test-ehr"
export CRD_DIR="$DAVINCI_ROOT/repos/CRD"
export DTR_DIR="$DAVINCI_ROOT/repos/dtr"
export CRG_DIR="$DAVINCI_ROOT/repos/crd-request-generator"
export PAS_DIR="$DAVINCI_ROOT/repos/prior-auth"
export CDSLIB_DIR="$DAVINCI_ROOT/repos/CDS-Library"

# --- shared cross-service config ---
# Fix #4: CRD inherits HAPI's Elasticsearch health contributor but runs on H2,
# so /actuator/health reports a permanent DOWN. Without this it is UP.
export MANAGEMENT_HEALTH_ELASTICSEARCH_ENABLED=false

# Item 18 fallout, previously unrecorded: upstream corsOrigins is
# 3000, 3002, 3005 — it does NOT include 3001, so a browser on :3001 is
# CORS-blocked by CRD. Relaxed binding replaces the whole list, so the
# upstream entries we still want are repeated here.
export CORS_ORIGINS="http://localhost:3001,http://localhost:3005,http://localhost:8080,http://localhost:3000,http://localhost:3002"

# Also allow the box's real IPv4 addresses, so the UI works when it is opened by
# name/IP rather than by localhost -- from Windows via the WSL address, or from
# another machine on the network. Without this the stack binds 0.0.0.0 and still
# fails in the browser: crg on :3001 calls CRD on :8090 cross-origin, and an
# origin like http://192.0.2.10:3001 is not in the allow-list, so CRD answers
# 403 with no Access-Control-Allow-Origin and the browser drops every call. The
# UI then looks broken while all five services are demonstrably healthy.
#
# Computed rather than hardcoded: the WSL address is DHCP-assigned and changes
# across reboots, so a baked-in value silently rots.
for _ip in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
  # Derived from STACK_PORTS, not spelled out: hardcoding the list here is how
  # :8180 came up missing the first time round.
  for _p in ${STACK_PORTS//|/ }; do
    CORS_ORIGINS="$CORS_ORIGINS,http://$_ip:$_p"
  done
done
unset _ip _p
export CORS_ORIGINS

# PAS dispatches its final disposition on this timer, so the demo has a real
# PENDING -> GRANTED transition to show rather than a fake one.
export DELAY=15000

# DTR. Both defaults upstream already point at our EHR, stated here so the
# swap point is visible in one place (PLAN.md §7). The EHR base is /fhir/r4 —
# the IRIS instance fronted by bin/ehr-shim on $TEST_EHR_PORT.
export REACT_APP_SERVER_PORT="$DTR_PORT"
export REACT_APP_INITIAL_CLIENT="http://$ADVERTISE_HOST:$TEST_EHR_PORT/fhir/r4::app-login"

# crd-request-generator. PORT is the backend; the nine REACT_APP_* values are
# resolved in the BROWSER, and src/properties.json already ships our topology.
#
# PORT is deliberately NOT exported here. dtr's bin/www does
# `normalizePort(process.env.PORT || serverPort)` — plain PORT wins over
# REACT_APP_SERVER_PORT — so a global PORT=3001 intended for crg silently
# drags dtr onto 3001, where it then collides with crg's own EADDRINUSE.
# up.sh passes PORT per service instead.
export REACT_APP_EHR_SERVER="http://$ADVERTISE_HOST:$TEST_EHR_PORT/fhir/r4"
export REACT_APP_CDS_SERVICE="http://$ADVERTISE_HOST:$CRD_PORT/r4/cds-services"
export REACT_APP_ORDER_SELECT="order-select-crd"
export REACT_APP_ORDER_SIGN="order-sign-crd"
export REACT_APP_LAUNCH_URL="http://$ADVERTISE_HOST:$DTR_PORT/launch"
export REACT_APP_PUBLIC_KEYS="http://$ADVERTISE_HOST:$CRG_PORT/public_keys"
export REACT_APP_CLIENT="app-login"

# Optional: a VSAC API key lifts fix item 19 (67 value sets). Absent is
# non-fatal — rules still evaluate, but value-set-gated rules cannot match.
# export VSAC_API_KEY=...

demo_note() { printf '\n== %s ==\n' "$*"; }
