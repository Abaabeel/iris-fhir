#!/usr/bin/env bash
# demo.sh — the frozen DaVinci path, unattended, with an assertion at every step.
#
#   bin/up.sh --reset   # or bin/up.sh if the stack is already warm
#   bin/demo.sh
#
# Exits non-zero on the first failed assertion, so it is usable as a smoke test
# in CI or as a pre-demo confidence check. Safe to run repeatedly.
#
# Scope note: this covers the API-reachable path (card -> PAS). The DTR browser
# hop is NOT covered and cannot be, with the shipped test-ehr — see the "DTR
# gap" block at the bottom for the measured reason.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

FIXTURES="$DAVINCI_ROOT/fixtures"
WORK="$DAVINCI_ROOT/state/demo"
EHR_FHIR="http://localhost:$TEST_EHR_PORT/fhir/r4"
PAS="$PAS_DIR/src/test/resources/bundle-items.json"

# 15s DELAY + generous margin; we poll, so this is a ceiling not a sleep.
GRANT_TIMEOUT="${GRANT_TIMEOUT:-60}"

pass=0; fail=0
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'
else G=""; R=""; B=""; N=""; fi

step() { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }
ok()   { pass=$((pass+1)); printf '  %sok%s   %s\n'   "$G" "$N" "$1"; }
bad()  { fail=$((fail+1)); printf '  %sFAIL%s %s\n' "$R" "$N" "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
die()  { bad "$1" "${2:-}"; printf '\n%s%d passed, %d failed%s\n' "$B" "$pass" "$fail" "$N"; exit 1; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

mkdir -p "$WORK"

# ---------------------------------------------------------------- preflight --
step "preflight: stack reachable"
for spec in "crd|http://localhost:$CRD_PORT/r4/cds-services" \
            "pas|http://localhost:$PAS_PORT/fhir/metadata"; do
  name="${spec%%|*}"; url="${spec#*|}"
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url")"
  [ "$code" = 200 ] || die "$name not reachable ($code)" "run: bin/up.sh"
  ok "$name reachable"
done

# A 200 on / is not proof the client registered; the SMART link needs the id.
clients="$(curl -s -m 10 "http://localhost:$DTR_PORT/clients" || echo '[]')"
[ "$(printf '%s' "$clients" | tr -d ' \n')" = "[]" ] \
  && die "dtr has no registered client" "check $LOGDIR/dtr.log — databaseData/ must exist"
ok "dtr client registered"

# ------------------------------------------------- 1. CRD returns a card ------
step "1. CRD: order-sign on pat013 / E0607 -> coverage card"
code="$(curl -s -m 60 -o "$WORK/card.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d @"$FIXTURES/order-sign-prefetch.json" \
  "http://localhost:$CRD_PORT/r4/cds-services/order-sign-crd")"
[ "$code" = 200 ] || die "order-sign-crd returned $code" "see $LOGDIR/crd.log"
ok "HTTP 200"

summary="$(python3 -c "
import json;c=json.load(open('$WORK/card.json')).get('cards',[{}])[0]
print(c.get('summary',''))" 2>/dev/null)"
[ -n "$summary" ] || die "no card in response"
ok "card: $summary"

# The questionnaire canonical is what the EHR turns into a DTR launch link.
questionnaire="$(python3 -c "
import json
c=json.load(open('$WORK/card.json')).get('cards',[{}])[0]
for s in c.get('suggestions',[]) or []:
  for a in s.get('actions',[]) or []:
    def walk(e):
      if isinstance(e,dict):
        if e.get('url')=='questionnaire': return e.get('valueCanonical')
        for v in e.values():
          r=walk(v)
          if r: return r
      elif isinstance(e,list):
        for v in e:
          r=walk(v)
          if r: return r
    for act in (a.get('resource',{}) or {}).get('extension',[]) or []:
      q=walk(act)
      if q: print(q); raise SystemExit
" 2>/dev/null)"
[ -n "$questionnaire" ] || die "card carries no questionnaire canonical" "DTR cannot be linked"
ok "questionnaire: $questionnaire"

# ------------------------------------- 1b. the SMART link actually builds ----
step "1b. card -> DTR launch link (handshake half only)"
launch_id="$(curl -sL -m 20 -X POST -H 'Content-Type: application/json' \
  -d "{\"launchUrl\":\"http://localhost:$DTR_PORT/launch\",\"parameters\":{\"patient\":\"pat013\"}}" \
  "$EHR_FHIR/_services/smart/Launch" \
  | python3 -c "import json,sys;print(json.load(sys.stdin).get('launch_id',''))" 2>/dev/null)"
[ -n "$launch_id" ] || die "EHR did not return a launch_id" "the card's SMART link would dead-end"
ok "launch_id issued: $launch_id"
ok "link crg would open: http://localhost:$DTR_PORT/launch?launch=$launch_id&iss=$EHR_FHIR"

# ------------------------------------------------------ 2. PAS $submit --------
step "2. PAS: \$submit the provider bundle"
code="$(curl -s -m 60 -o "$WORK/claimresponse.json" -w '%{http_code}' \
  -H 'Content-Type: application/fhir+json' \
  -d @"$PAS" "http://localhost:$PAS_PORT/fhir/Claim/\$submit")"
[ "$code" = 201 ] || die "\$submit returned $code (expected 201)" "see $LOGDIR/prior-auth.log"
ok "HTTP 201"

read -r preauth items <<<"$(python3 -c "
import json
d=json.load(open('$WORK/claimresponse.json'))
for e in d.get('entry',[]):
  r=e.get('resource',{})
  if r.get('resourceType')=='ClaimResponse':
    print(r.get('preAuthRef',''), len(r.get('item',[])))" 2>/dev/null)"
[ -n "$preauth" ] || die "no ClaimResponse in the \$submit response"
ok "preAuthRef: $preauth"
[ "${items:-0}" = 2 ] || bad "expected 2 items, got ${items:-0}"
check $([ "${items:-0}" = 2 ] && echo 0 || echo 1) "2 authorization items"

# ------------------------------------- 3. poll to GRANTED (never sleep) -----
step "3. PAS: poll async disposition (DELAY=${DELAY}ms, ceiling ${GRANT_TIMEOUT}s)"
deadline=$(( $(date +%s) + GRANT_TIMEOUT ))
disposition=""; polled=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  polled=$((polled+1))
  # The debug view is an HTML table, one <tr> per stored bundle, sorted
  # NEWEST FIRST. PAS keeps the same preAuthRef and appends a newer row when the
  # timer grants it, so the FIRST match for our ref is the current disposition
  # and later matches are the superseded history (A4 pending -> A1 complete).
  # Taking the last match silently asserts on the oldest row and hangs.
  # The stored JSON title-cases the disposition ("Granted"), unlike the log.
  disposition="$(curl -s -m 10 "http://localhost:$PAS_PORT/fhir/debug/ClaimResponse" \
    | python3 -c "
import re, sys
html = sys.stdin.read()
ref = '$preauth'
for row in html.split('<tr>'):
    if ref in row:
        d = re.search(r'\"disposition\"\s*:\s*\"(\w+)\"', row)
        if d:
            print(d.group(1).upper())
            break
" 2>/dev/null)"

  [ "$disposition" = "GRANTED" ] && break
  case "$disposition" in DENIED|TERMINATED) break;; esac
  sleep 2
done
printf '  (%d polls)\n' "$polled"
[ "$disposition" = "GRANTED" ] || die "final disposition was '${disposition:-unknown}' (wanted GRANTED)"
ok "PENDING -> GRANTED"

# --------------------------------------------------------------- summary -----
printf '\n%sPASS%s  %d assertions, 0 failures\n' "$G" "$N" "$pass"
printf '      card      %s\n' "$summary"
printf '      preAuth   %s\n' "$preauth"
printf '      granted   %s after %d polls\n' "$disposition" "$polled"
cat <<'EOF'
  Not covered above: the browser half of the flow. This script posts the Claim
  itself, so it never exercises the SMART handshake (crg -> test-ehr /auth ->
  Keycloak :8180 -> dtr), the questionnaire, or the Claim that dtr builds for
  itself from the QuestionnaireResponse. That path is closed now and has its
  own driver:

      python3 bin/e2e-browser.py
EOF
[ "$fail" = 0 ] || exit 1
