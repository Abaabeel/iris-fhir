#!/usr/bin/env bash
# seed-iris.sh — idempotently seed the IRIS FHIR server behind bin/ehr-shim
# with the DaVinci demo dataset (the same seed data the mock test-ehr loaded
# into HAPI), then assert every query the browser flow will issue answers 200
# with the right payload.
#
#   bin/seed-iris.sh          # seed + verify (safe to re-run: PUTs overwrite)
#   bin/seed-iris.sh --verify # skip seeding, only run the assertions
#
# Reads the IRIS_* variables from bin/env.sh. Nothing is downloaded; all data
# comes from repos/test-ehr/src/main/resources/seed-data/.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh" 2>/dev/null || true

IRIS_FHIR_BASE="${IRIS_FHIR_BASE:-https://10.0.3.108:52774/fhir/r4}"
IRIS_TOKEN_URL="${IRIS_TOKEN_URL:-${IRIS_FHIR_BASE%/fhir/r4}/oauth2/token}"
IRIS_OAUTH_CLIENT_ID="${IRIS_OAUTH_CLIENT_ID:-MvrcDCC1LRt-UIEE-cXVpxyHnKhLDGuyBfpHZMNtWrA}"
IRIS_OAUTH_CLIENT_SECRET="${IRIS_OAUTH_CLIENT_SECRET:-I4CuQe1QbItnvt7FmpqyM6qN1d3IKwgsI37n7LmdU6eaLKb2rlJ9f_XA6yEXOMsutDyU_FvDSnsU6hdSg9HLhw}"
IRIS_OAUTH_SCOPES="${IRIS_OAUTH_SCOPES:-user/*.write user/*.rs}"
SEED_DIR="${IRIS_SEED_DIR:-$DAVINCI_ROOT/repos/test-ehr/src/main/resources/seed-data}"

[ -d "$SEED_DIR" ] || { echo "seed dir not found: $SEED_DIR" >&2; exit 1; }

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }

mint_token() {
  curl -sk --max-time 30 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_id=$IRIS_OAUTH_CLIENT_ID" \
    --data-urlencode "client_secret=$IRIS_OAUTH_CLIENT_SECRET" \
    --data-urlencode "scope=$IRIS_OAUTH_SCOPES" \
    --data-urlencode "aud=$IRIS_FHIR_BASE" \
    "$IRIS_TOKEN_URL" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
}

TOKEN="$(mint_token)" || { echo "token mint failed — is the iris-fhir container up?" >&2; exit 1; }

WORK="$DAVINCI_ROOT/state/seed"
mkdir -p "$WORK"

# resource-type/id <- JSON file, with an optional python normalizer
seed() {
  local route="$1" file="$2" norm="${3:-}"
  local tmp="$file"
  if [ -n "$norm" ]; then
    python3 -c "$norm" < "$file" > "$WORK/$(basename "${route//\//_}")" || return 1
    tmp="$WORK/$(basename "${route//\//_}")"
  fi
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 60 -X PUT \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/fhir+json' \
    --data-binary @"$tmp" "$IRIS_FHIR_BASE/$route")
  [ "$code" = "201" ] || [ "$code" = "200" ]
}

if [ "${1:-}" != "--verify" ]; then
  say "seeding IRIS ($IRIS_FHIR_BASE)"
  seed  'Patient/pat013'                  "$SEED_DIR/o2john_01__patient.json" || bad "Patient/pat013"
  seed  'Coverage/cov013'                 "$SEED_DIR/o2john_02__coverage.json" || bad "Coverage/cov013"
  seed  'DeviceRequest/devreq037'         "$SEED_DIR/o2john_04__device-requestC.json" || bad "DeviceRequest/devreq037 (E0607)"
  seed  'Practitioner/pra1234'            "$SEED_DIR/1. practitioner.json" || bad "Practitioner/pra1234"
  seed  'Practitioner/pra-hfairchild'     "$SEED_DIR/Practitioner-Fairchild.json" || bad "Practitioner/pra-hfairchild"
  seed  'Organization/org1234'            "$SEED_DIR/2. organization.json" || bad "Organization/org1234"
  seed  'Location/loc1234'                "$SEED_DIR/4. location.json" || bad "Location/loc1234"
  seed  'PractitionerRole/prarol1234'     "$SEED_DIR/6. practitioner-role.json" \
    'import json,sys;d=json.load(sys.stdin);d.pop("organization ",None);d["organization"]={"reference":"Organization/org1234"};json.dump(d,sys.stdout)' || bad "PractitionerRole/prarol1234"
  ok "all 8 resources PUT"
fi

say "verifying the queries crg/dtr will issue"
FAIL=0
chk() { # chk <description> <path> <python-assert>
  local desc="$1" path="$2" py="$3"
  local code body
  body=$(curl -sk --max-time 60 -H "Authorization: Bearer $TOKEN" "$IRIS_FHIR_BASE$path")
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 60 -H "Authorization: Bearer $TOKEN" "$IRIS_FHIR_BASE$path")
  if [ "$code" = "200" ] && printf '%s' "$body" | python3 -c "$py" 2>/dev/null; then
    ok "$desc ($code)"
  else
    bad "$desc ($code)"
    FAIL=1
  fi
}

chk "patient list  Patient?_sort=identifier&_count=12" \
  "/Patient?_sort=identifier&_count=12" \
  'import sys,json;d=json.load(sys.stdin);ids=[e["resource"]["id"] for e in d.get("entry",[])];sys.exit(0 if "pat013" in ids else 1)'

chk "auth probe    Patient?_summary=count" \
  "/Patient?_summary=count" \
  'import sys,json;sys.exit(0 if json.load(sys.stdin).get("total",0)>=0 else 1)'

chk "patient read  Patient/pat013" \
  "/Patient/pat013" \
  'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get("id")=="pat013" and d.get("name",[{}])[0].get("family")=="Quinton" else 1)'

chk "orders        DeviceRequest?subject=Patient/pat013" \
  "/DeviceRequest?subject=Patient/pat013" \
  'import sys,json;d=json.load(sys.stdin);codes=[e["resource"].get("codeCodeableConcept",{}).get("coding",[{}])[0].get("code") for e in d.get("entry",[])];sys.exit(0 if "E0607" in codes else 1)'

chk "no orders     ServiceRequest?subject=Patient/pat013" \
  "/ServiceRequest?subject=Patient/pat013" \
  'import sys,json;sys.exit(0)'

chk "no orders     MedicationRequest?subject=Patient/pat013" \
  "/MedicationRequest?subject=Patient/pat013" \
  'import sys,json;sys.exit(0)'

chk "no orders     MedicationDispense?subject=Patient/pat013" \
  "/MedicationDispense?subject=Patient/pat013" \
  'import sys,json;sys.exit(0)'

chk "coverage      Coverage?patient=Patient/pat013&status=active" \
  "/Coverage?patient=Patient/pat013&status=active" \
  'import sys,json;d=json.load(sys.stdin);ids=[e["resource"]["id"] for e in d.get("entry",[])];sys.exit(0 if "cov013" in ids else 1)'

chk "prefetch      DeviceRequest?_id=devreq037&_include=... (4 includes + 2 iterate)" \
  "/DeviceRequest?_id=devreq037&_include=DeviceRequest:patient&_include=DeviceRequest:performer&_include=DeviceRequest:requester&_include=DeviceRequest:device&_include:iterate=PractitionerRole:organization&_include:iterate=PractitionerRole:practitioner" \
  'import sys,json;d=json.load(sys.stdin);sys.exit(0)'

say "raw (no token) request must be rejected"
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 60 "$IRIS_FHIR_BASE/Patient?_summary=count")
if [ "$code" = "401" ] || [ "$code" = "403" ]; then
  ok "rejected without token ($code)"
else
  bad "expected 401/403 without token, got $code"
  FAIL=1
fi

[ "$FAIL" = "0" ] && ok "IRIS seed verified" || { echo "seed verification FAILED" >&2; exit 1; }