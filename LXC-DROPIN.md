# LXC-DROPIN.md — the iris-fhir LXC image: end-to-end from a fresh Ubuntu host

This repo + a single prebuilt LXC image = the complete DaVinci prior-auth E2E
(**CRD → DTR → PAS**) running against an IRIS FHIR server, no container runtime
for the stack itself, no manual IRIS install, no InterSystems account.

The image contains the **IRIS half** (what no script can rebuild for you): a
provisioned IRIS for Health Community 2026.2 instance with the generated OAuth
confidential client, the mock TLS cert, and the DaVinci seed data. The **stack
half** (Keycloak, CRD, dtr, crg, prior-auth, ehr-shim) runs on your host from
this repo, exactly as before — because dtr submits the Claim from the browser,
the two drivers (`demo.sh`, `e2e-browser.py`) are what prove the E2E.

Target: **Ubuntu 24.04, root, ~12 GB free disk, LXC**. Total time ≈ 25 min.

---

## The contract you're agreeing to

| Thing | Value | Must be true on your host |
|---|---|---|
| Container IP | **10.0.3.108** (static, inside the image) | default `lxcbr0` from lxc-net — nothing else on `.108` |
| IRIS FHIR (TLS) | `https://10.0.3.108:52774/fhir/r4` | reachable from the host |
| Mock TLS cert | self-signed `CN=iris-fhir`, public copy in `bin/ehr-shim/iris-fhir.crt` | the ehr-shim trusts it; your curl needs `-k` or the `.crt` |
| IRIS OAuth fixture | confidential client in `bin/env.sh` defaults | matches the client baked into the image — **do not rotate** unless you rebuild the image |
| Superuser | IRIS `_SYSTEM` account (install-time password) | you never need it for the E2E |

**Licensing note:** IRIS for Health Community is InterSystems' free
development/demo distribution. This image redistributes that proprietary
software, so confirm the community license covers your use before going beyond
a demo. The image is shared as-is, with mock data only.

**Design note (why two pieces):** IRIS is proprietary and multi-GB; the stack is
open-source and rebuilt from pinned SHAs (`versions.lock`). Splitting them means
the only "can't reproduce by script" part is the shipped artifact, and the rest
stays verifiable in git.

---

## Step 0 — one-time host prep (2 min)

```bash
sudo apt update && sudo apt install -y lxc curl python3
sudo systemctl restart lxc-net      # creates lxcbr0 (10.0.3.1) if not up
ip -4 addr show lxcbr0              # expect 10.0.3.1/24
```

## Step 1 — drop the image in (5–10 min, mostly download)

```bash
git clone https://github.com/Abaabeel/iris-fhir.git
cd iris-fhir
sudo bash bin/lxc-import.sh github
```

That downloads the release parts, verifies checksums, extracts under
`/var/lib/lxc/iris-fhir`, starts the container and waits for the FHIR endpoint:

```bash
curl -sk https://10.0.3.108:52774/fhir/r4/metadata -o /dev/null -w '%{http_code}\n'   # 200
lxc-ls -f | grep iris-fhir                                                            # RUNNING
```

Alternatives to `github` as the source argument: a local directory of parts, a
single `.tar.gz`, or explicit asset URLs. If the remote is unreachable you can
download manually: open the release page
`https://github.com/Abaabeel/iris-fhir/releases/latest`, grab every
`iris-fhir-image.tar.gz.partNN` file + `parts.sha256`, put them in one dir and
`sudo bash bin/lxc-import.sh <that-dir>`.

## Step 2 — run the stack (10–20 min; one-time provisioning, then fast)

```bash
# already cloned in step 1
./bin/provision.sh --check          # MUST report "all inputs present", exit 0
./bin/provision.sh                  # JDK17, Maven, Keycloak, the six upstream repos
./bin/up.sh                         # starts all six services + post-flight checks
./bin/seed-iris.sh                  # asserts the 9 crg/dtr IRIS queries answer 200
```

Post-flight `up.sh` output must show the crd doc-needed flag warmed and all six
endpoints `200` (keycloak:8180, ehr-shim:8080, crd:8090, prior-auth:9015,
dtr:3005, crg:3001).

## Step 3 — verify the E2E (5 min)

```bash
./bin/demo.sh              # 12 assertions, API only  → 12 passed, 0 failures
python3 bin/e2e-browser.py # 14 assertions, real browser → 14 passed, 0 failures
```

`e2e-browser.py` needs Playwright once:
`pip install playwright && playwright install chromium --with-deps`

Then open **http://localhost:3001/** and click through: coverage card → Keycloak
login (`dtr` / `dtr-demo`) → questionnaire → **Proceed To Prior Auth** → claim
goes Pending then Granted.

---

## What's actually inside the image

- Ubuntu 24.04 + IRIS for Health Community **2026.2.0.221.0** installed at
  `/opt/iris`, Apache + CSP serving FHIR R4 on `:52774` (TLS) and `:52773`.
- The generated OAuth confidential client (`ConfigureInternalOAuthClients`),
  matching `env.sh` — this is what the ehr-shim uses to mint bearer tokens.
- The DaVinci seed (patients pat013/pat015, device requests, coverage) loaded by
  `bin/seed-iris.sh`, idempotent on re-run.
- Trimmed for transport: no installer kit, apt caches, or logs. The IRIS WIJ,
  journals and ssh host keys ship **as-is** — deleting the WIJ makes IRIS
  believe the shutdown was abnormal and the box boots into single-user journal
  recovery (hit on 2026-09-30, recovered, then excluded from the recipe).
  **Raw ~7 GB → ~2.8 GB compressed** (2 GitHub release parts, ≤1.9 GB each).
- IRIS **auto-starts** at container boot via a baked-in `iris.service` systemd
  unit (`iris start FHIR`); its ExecStop shuts IRIS down inside a pty (the
  `iris stop` prompts read `/dev/tty` and would EOF-fail under plain systemd),
  so host reboots / `lxc-stop` leave a clean WIJ marker.
- `iris list` shows **`state: warn`** — expected, not a fault: IRIS Health's
  failover context has no mirror partner configured and the journal's primary
  vs archive directory are the same (single-disk install). FHIR serving is
  unaffected (it announces at every start since provisioning).

Not in the image (deliberately): the six-service stack, drivers and fixtures —
they live in this repo, reproducible from `versions.lock`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `lxc-import.sh github` can't download | release not published yet, or repo visibility; download parts manually from the release page and pass the dir |
| container starts but `52774` hangs | another host took `10.0.3.108`; check `cat /var/lib/misc/dnsmasq.lxcbr0.leases`; free the IP or change `IRIS_FHIR_BASE` in `env.sh` + the container's `/etc/netplan/10-lxc.yaml` (`netplan apply`, `lxc-stop/start`) |
| `provision.sh --check` fails | fix the named input and re-run — it reports exactly what's missing |
| six probes green but browser e2e fails at the SMART launch | CRD's write-once doc-needed flag got poisoned by a cold-boot POST that wasn't `up.sh` (see AGENTS.md trap 6); restart CRD so `up.sh`'s warmup is its first POST |
| `downloads` dir import fails checksum | re-download parts; `sha256sum -c parts.sha256` names the bad file |
| `iris list` shows `state: warn` | expected — unconfigured HealthShare failover context; benign, serving unaffected |
| Windows / WSL2 host | works under WSL2 with lxc-utils, but pick a stable host; this repo's stack is Linux-only |

## Rebuilding the image (maintainers only)

On the machine that owns the blessed container, after re-seeding or upgrading
IRIS:

```bash
sudo bash bin/lxc-image-build.sh        # stop→trim→tar→split→sha into /root/lxc-dist
```

The script refuses to package a DHCP-configured container — the static IP is
part of the image contract.