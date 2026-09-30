# The DaVinci Prior-Authorization E2E on InterSystems IRIS for Health

**A drop-in laboratory: the real HL7 DaVinci prior-authorization workflow
(CRD → DTR → PAS), end to end, on your own machine, driven to a real
`Pending → Granted` decision against a real InterSystems IRIS for Health FHIR
server — no cloud, no PHI, no InterSystems account, no container runtime for
the stack itself.**

You download one prebuilt LXC image (a provisioned IRIS for Health instance),
import it with one command, start six services with one script, and watch a
real browser walk through: coverage card → real OIDC login → payer
questionnaire → a `Claim` that a SMART app builds for itself → a prior-auth
decision.

![the CRD coverage card](docs/screenshots/01-crd-card.png)

> **All patient data is synthetic** — upstream's own test fixtures (`Tables,
> Bobby`, `Quinton, Vlad`, invented MRNs). No real patient, no real PHI,
> anywhere, including the screenshots. Please keep it that way.

---

## Contents

- [Why this exists](#why-this-exists) — the problem we are trying to solve
- [What we are trying to achieve](#what-we-are-trying-to-achieve) — the design
- [What is in it for you](#what-is-in-it-for-you) — digital-health/HIS perspective, and the AI canvas
- [How it works](#how-it-works) — architecture and the end-to-end flow
- [Install — Path A: the drop-in image](#install--path-a-the-drop-in-image-recommended) (recommended)
- [Install — Path B: provision from source](#install--path-b-provision-from-source)
- [Run and verify](#run-and-verify)
- [Walkthrough: the browser path](#walkthrough-the-browser-path)
- [Reference](#reference) — ports, endpoints, credentials, security
- [Known limitations](#known-limitations)
- [Repository layout](#repository-layout)
- [Glossary](#glossary)
- [Further reading](#further-reading)

**Last verified:** 2026-09-30. Green run: `demo.sh` 12/12, `e2e-browser.py`
14/14, image cold-boot verified from the public release. Pins in
`versions.lock` are the run version.

---

## Why this exists

### Prior authorization is one of healthcare's largest administrative wound

Prior authorization (PA) is the gate a payer runs before it will cover a
prescribed service, medication, or device. The intent — medical necessity,
cheaper alternatives, safety — is legitimate. The mechanism is not.

The process is still largely manual. A widely cited 2018 study found **88% of
prior-authorization work is partially or entirely manual**; another found a
typical request flows through faxes, portals, and phone queues, with payers
allowed up to **30 days** to decide. The cost shows up at every level:

| Fact | Source |
|---|---|
| US system cost of PA was estimated at **$23–31 B per year** | Casalino et al., *Health Affairs*, 2009 |
| Physicians ~**1.1 h/week**, nursing **13.1 h/week**, clerical **5.6 h/week** on PA per practice | Casalino et al., *Health Affairs*, 2009 |
| **$2,161–$3,430 per physician per year** in PA handling cost | *J. Am. Board of Family Medicine*, 2012 |
| **401% more prevalent** in 2021 than a decade earlier (Medicare Advantage) | widely cited payer-request counts |
| Electronic PA produced **~90% faster payer response** in a PBM case study | Prime Therapeutics (via Wikipedia's PA article) |

Every digit is a delay in care and a diversion of clinical staff.

### The regulator is forcing the fix — on FHIR

In January 2024 CMS finalized **CMS-0057-F**, *Advancing Interoperability and
Improving Prior Authorization Processes*. It requires Medicare Advantage
plans, Medicaid managed care plans, and Qualified Health Plan issuers to
implement:

- a **Patient Access API**,
- a **Provider Access API**, and
- a **Prior Authorization API**,

all on the **HL7 FHIR R4** standard, with deadlines through **January 2027
(large payers)** and **January 2028 (small payers)**. The Prior Authorization
API must support **72-hour urgent** and **7-day standard** decisions, remain
available ~24/7, and provide **real-time decisions** for "routinely approved"
items and services. It follows the earlier **CMS-9115-F** (2020) that started
the FHIR Patient Access wave, and it is why payers now openly market
"CMS-0057-ready" products. The standards-based answer to all of this is the
HL7 **DaVinci** project and its FHIR implementation guides.

### The standards exist. Nobody can see them working.

The **HL7 DaVinci Project** (co-founded in 2018 with Blues-affiliated payer
sponsorship and CMS engagement) publishes the implementation guides that turn
this regulation into machine-readable workflow:

- **CRD — Coverage Requirements Discovery**: at order/referral time, a CDS
  hook asks the payer, "does this order have coverage or documentation
  requirements?" and gets back a card.
- **DTR — Documentation Templates and Rules**: the clinician launches a SMART
  app that retrieves the payer's questionnaire + CQL rules, pre-fills from
  the record where possible, and produces the documentation as structured
  FHIR.
- **PAS — Prior Authorization Support**: the resulting request is submitted
  to the payer's FHIR endpoint (`Claim/$submit`) and answered with a
  `ClaimResponse` — pending, granted, or denied.

Three documented DaVinci implementers could not, by themselves, make the
whole loop visible. **This repo is the whole loop, running locally.** You can
read the code, step through it, break it, and re-run it — which is the
difference between "the FHIR future is coming" and "I have watched it work."

---

## What we are trying to achieve

Five goals, in priority order:

1. **A faithful, reproducible E2E of CRD → DTR → PAS** on real upstream
   DaVinci code pinned to exact SHAs — not a hand-rolled imitation. When the
   mocks need retiring, the real service drops into the same slot.
2. **A real clinical-data platform underneath**: the EHR half is a genuine
   **InterSystems IRIS for Health** FHIR server, not a stub. That is the
   difference between a demo and an integration test.
3. **Zero setup tax**: a prebuilt, checksum-verified **drop-in image** so an
   end user goes from zero to a working prior-auth decision in minutes, with
   no InterSystems install, no license request, no cloud account.
4. **Verifiable by two independent drivers**: an API driver (`demo.sh`,
   12 assertions) and a real-browser driver (`e2e-browser.py`, 14
   assertions) — *both* required, because each covers a leg the other cannot.
5. **Safe to hand to an AI agent**: `AGENTS.md` is a self-contained playbook
   (provision → start → verify → report → stop) with the traps documented so
   an agent does not rediscover them.

> The load-bearing fact that shapes the whole design: **dtr submits the
> Claim, not the EHR.** Clicking `PROCEED TO PRIOR AUTH` makes dtr's
> questionnaire build a `Claim` from its own `QuestionnaireResponse` and swap
> in a panel whose `Submit` POSTs `Claim/$submit`. Nothing in the EHR half
> references PAS at all — so the API driver, which posts the Claim itself,
> can never cover the browser leg, and vice versa.

### Why InterSystems IRIS for Health

This is not a toy:

- **IRIS for Health** is positioned by InterSystems as *"a digital health
  data platform that provides the building blocks needed to work with any
  healthcare data standard, including FHIR."* It ships a native **FHIR R4
  repository** (CRUD, search, operations, transactions), an integration
  engine (**Health Connect**: HL7 v2, X12, IHE, FHIR), multi-model storage
  (objects + SQL + documents in one engine), SQL access to everything,
  embedded analytics, and — increasingly — **vector search** for GenAI
  applications.
- It is the **production spine** of real hospital systems (TrakCare EHR,
  HealthShare HIE, EMPI/identity, OMOP pipelines) and, per InterSystems'
  published success stories, of **FHIR-scale AI workloads** (Stanford Health
  Care: "Meeting Stringent Healthcare AI Performance Demands with FHIR").
- InterSystems itself markets **Payer Services** specifically to help U.S.
  insurers address **CMS-0057** — the same regulation this repo demonstrates
  from the provider side.
- **Community Edition is free** and the instance in this project is IRIS for
  Health Community 2026.2. The image has it fully provisioned: OAuth
  confidential client, TLS, seeded DaVinci demo data.

The design sentence: *the payer side is DaVinci code, the provider side is an
IRIS instance, and the two speak FHIR R4 to each other exactly the way the
regulation intends.*

---

## What is in it for you

Written for a digital-health professional who runs **HIS** (health
information systems) in a hospital and thinks about the bigger health and AI
canvas.

### Provider-side: this is your payer-interoperability future, decompressed

Your hospital's EHR must soon talk to payer FHIR APIs (Patient Access,
Provider Access, Prior Auth). That is not a procurement leaflet — it is
CDS Hooks at order time, SMART app launches, and structured questionnaires.
This repo shows you each of those mechanisms working, with logs you can read:

| Question you may be asking | What this repo shows you |
|---|---|
| "What does an order-time coverage check actually look like?" | the CRD card on the coverage request (`order-sign-crd`) |
| "How does a SMART app launch inside an EHR?" | the real OIDC redirect through Keycloak when you click the card |
| "What is a payer questionnaire / DTR?" | the rendered questionnaire with live value-set answer options |
| "How does a prior-auth request reach a payer as data?" | dtr builds the `Claim`; `Claim/$submit` returns 201; `Pending → Granted` |
| "What are value sets and CQL and VSAC?" | 65 value sets seeded from public terminology; CRD evaluates them |

**That is the difference between knowing FHIR on paper and having watched it
work.**

### HIS-side: the building blocks of the FHIR-based hospital

Under one roof you get the real components a FHIR-capable HIS hinges on:
FHIR R4 resources and CapabilityStatements, SMART OAuth (via Keycloak),
CDS Hooks, terminology/value-set management, and a genuine multi-model
clinical data platform (IRIS) behind it all. You can point a FHIR client at
`https://10.0.3.108:52774/fhir/r4`, query `Patient/pat013`, and see how a
real repository behaves — search, references, transactions, `$expand`.

### The bigger health canvas

The same standards stack is spreading beyond the US payer mandate: ONC
Information Blocking and the Cures Act (US), patient-mediated access in
Europe (**EHDS**), national digital health infrastructures (India ABDM,
Saudi, GCC, and others adopting FHIR), and payer-provider convergence
globally. The **workflow**, not just the API, is what this repo demonstrates —
which is the part most sandboxes omit.

### The AI canvas: why this project sits where AI is heading

Four honest reasons this mock is a useful place to think about AI in
healthcare:

1. **FHIR is the substrate AI needs.** Every LLM-based clinical feature
   (chart summarisation, prior-auth copilots, coding assistants, RAG over
   patient records) is only as good as the structured, queryable data
   underneath. FHIR is the common language; IRIS is a platform built to hold
   it — multi-model storage, SQL on FHIR, and vector search for semantic
   retrieval in the same engine. This repo hands you a running example of
   that substrate.
2. **Prior auth is one of AI's highest-value targets.** It is voluminous,
   paper-bound, and rule-documented — the perfect case for retrieval +
   drafting + verification: an AI assistant that drafts the DTR
   questionnaire answers, pulls the supporting value sets and codes, and
   generates the attachment payload, with a clinician signing off.
3. **Deterministic rules are the guardrail, not the enemy.** The DaVinci
   stack decides with CQL + value sets — auditable, explainable logic. The
   realistic architecture is *hybrid*: LLMs draft and summarise; deterministic
   rules adjudicate and validate. This repo gives you both halves to
   experiment with.
4. **Agents need tool access — FHIR is the tool surface.** This environment
   is a sandbox where an agent (or a human) can exercise CRD, DTR, PAS, and an
   IRIS FHIR server end-to-end locally. The repo even ships an agent playbook
   (`AGENTS.md`). Whatever your "AI in healthcare" idea is, a local,
   claim-driving, PHI-free loop is the cheapest place to start it.

Bottom line for you: **this is the smallest machine that contains the whole
future-proofed loop — payer rules, SMART workflow, structured data on a real
clinical platform, and a decision at the end.** Run it once and you will
never again have to imagine what FHIR-based prior auth is.

---

## How it works

```
   ┌──────────────  your machine  ──────────────┐   ┌──── LXC container (the image) ────┐
   │                                            │   │                                 │
   │  browser ──► crg :3001  ──►  CRD :8090     │   │   IRIS for Health (instance FHIR)│
   │   mock EHR UI         CDS Hooks:           │   │    · FHIR R4 repository          │
   │   (patient picker)    order-sign-crd        │   │    · https://10.0.3.108:52774   │
   │        │                    │              │   │    · OAuth client + TLS + seed   │
   │        │  SMART launch      │ card:        │   │    · auto-start systemd unit     │
   │        ▼                    │ "Documentation│  │                                 │
   │   Keycloak :8180            │  Required"    │   └─────────────────────────────────┘
   │   (real OIDC login)         ▼              │            ▲
   │        │              dtr :3005            │            │  /fhir/r4/*
   │        ▼              SMART app:           │      ehr-shim :8080  (mints bearer)
   │   questionnaire ──►  fill → builds Claim ──┼────────────┘
   │        │                 │                 │
   │        │                 ▼ Submit          │
   │        └────────►  PAS :9015  Claim/$submit 201 → PENDING → (15 s) → GRANTED
   └────────────────────────────────────────────┘
```

The flow, in plain terms:

1. **Order** — a clinician (you, in the mock EHR at `:3001`) picks a patient
   and an order (e.g. *E0607 — home blood glucose monitor*) and submits it to
   CRD.
2. **Discover** — CRD evaluates payer coverage rules (CQL + value sets) and
   returns a card: *"Documentation Required — complete the Home Blood Glucose
   Monitor Order in DTR."*
3. **Launch** — clicking the card launches DTR as a SMART app: a real OIDC
   redirect through Keycloak, then the payer's questionnaire renders.
4. **Document** — the clinician fills the questionnaire; dtr can pre-fill
   from the record (here it arrives un-prefilled — see
   [Known limitations](#known-limitations)). `PROCEED TO PRIOR AUTH` builds
   the `Claim`.
5. **Submit** — dtr's prior-auth panel POSTs `Claim/$submit` to PAS → `201`;
   PAS evaluates (15 s simulation) → **`PENDING` → `GRANTED`**, visible in
   the browser.

| Driver | Type | Asserts | Covers |
|---|---|---|---|
| `bin/demo.sh` | API only | 12 | card → questionnaire canonical → SMART `launch_id` → `Claim/$submit` 201 → `PENDING` → `GRANTED` |
| `bin/e2e-browser.py` | real browser (Playwright) | 14 | all of the above **plus** the Keycloak login and the `Claim` that **dtr builds itself** |

Both are required; neither is redundant.

### The moving parts

| Component | Port | Stack | Role |
|---|---|---|---|
| **IRIS for Health** (in the LXC image) | 52774 (TLS FHIR), 52773, 1972 | InterSystems IRIS for Health Community 2026.2 | the clinical data platform + FHIR R4 repository. R4 base: `https://10.0.3.108:52774/fhir/r4`. Auto-starts at container boot |
| **ehr-shim** | 8080 | Node | host-side proxy that holds the IRIS OAuth confidential client, mints a `client_credentials` bearer per call, and fronts `https://10.0.3.108:52774` — so the browser never needs an IRIS token |
| **CRD** | 8090 | Java/Quarkus, Gradle | CDS Hooks server + coverage rules; the `order-sign-crd` hook returns the "Documentation Required" card. Not a FHIR server |
| **prior-auth (PAS)** | 9015 | Java/Spring Boot 2.7, Gradle | `POST /fhir/Claim/$submit` → 201; CQL rules decide `Pending → Granted` on a 15 s timer |
| **Keycloak** | 8180 | Keycloak 26.7.4 | realm `BurdenReduction`, public client `app-login`, user `dtr` / `dtr-demo`. Exists so the DTR launch is a real OIDC redirect |
| **dtr** | 3005 | Node 22 / React 19 / Express 5 | the SMART app: login, questionnaire, **and builds + submits the Claim** |
| **crd-request-generator (crg)** | 3001 | Node 22 / React | the mock EHR UI you drive the demo from |

Deliberately independent process groups (plus the container): a crash in one
does not kill-loop the others, and each service has its own log
(`logs/<svc>.log`) and readiness probe.

> **Port 3000 is not used.** An unrelated Next.js app owns it on some hosts
> and `bin/down.sh` is written to leave it alone. crg runs on **3001**.

---

## Install — Path A: the drop-in image (recommended)

The image contains the **IRIS half** — the part no script can rebuild for
you: a provisioned IRIS for Health instance with OAuth client, TLS, seed
data, auto-start. The **stack half** (Keycloak, CRD, dtr, crg, prior-auth,
ehr-shim) runs on your host from this repo. No container runtime for the
stack; the container is just where IRIS lives.

**Target host:** Ubuntu 24.04 LTS, root, ~12 GB free disk, LXC. ≈ 25 minutes
total. Full runbook: [`LXC-DROPIN.md`](LXC-DROPIN.md).

```bash
# 1. host prerequisites
sudo apt-get update && sudo apt-get install -y lxc lxc-utils curl pigz git
sudo systemctl enable --now lxc-net          # creates lxcbr0 on 10.0.3.1

# 2. get the repo + the image in one command
git clone https://github.com/Abaabeel/iris-fhir.git
cd iris-fhir
sudo bash bin/lxc-import.sh github           # downloads + verifies + extracts + starts
```

`bin/lxc-import.sh github` does the whole drop-in: download the release
parts (`part00` + `part01`, ~2.5 GB) and both checksum files, assemble,
**verify the whole-archive SHA-256**, extract to `/var/lib/lxc/iris-fhir`,
start the container, and wait for TLS 200 on the FHIR endpoint. The release
is [`dropin-v1`](https://github.com/Abaabeel/iris-fhir/releases/tag/dropin-v1).

**What the image contract guarantees:**

| Thing | Value | Note |
|---|---|---|
| Container IP | `10.0.3.108` (static, inside the image) | your host must own `.108` on default `lxcbr0` |
| IRIS FHIR base | `https://10.0.3.108:52774/fhir/r4` | self-signed TLS — `curl -k`; ehr-shim trusts it by design |
| IRIS startup | automatic | baked-in `iris.service` systemd unit; clean shutdown writes a clean WIJ |
| `iris list` shows `state: warn` | expected | unconfigured HealthShare failover context; benign — serving unaffected |
| Credentials | none needed | the OAuth client lives inside the image; `bin/env.sh` knows it |

**Verify the container before bringing up the stack:**

```bash
lxc-ls -f | grep iris-fhir                 # RUNNING
curl -sk https://10.0.3.108:52774/fhir/r4/metadata -o /dev/null -w '%{http_code}\n'   # 200
```

Then continue at [Run and verify](#run-and-verify). (The stack scripts need
the container up: ehr-shim answers `:8080` and proxies to it.)

---

## Install — Path B: provision from source

Use this when you want the stack **without** the image (e.g. to build the
image yourself, or to run on a host without LXC against any other FHIR R4
server). This repo is the orchestration, not the payload: ~1.2 GB of upstream
clones and a ~337 MB toolchain are re-created from `versions.lock`.

### Requirements

| Need | Version | Notes |
|---|---|---|
| **Ubuntu** | 24.04 LTS (or close relative — Debian 12, Fedora 40+) | Linux only; Windows/macOS unsupported |
| `bash`, `git`, `curl`, `ss` (iproute2), `python3`, `unzip` | — | used by `bin/` |
| **Node.js** | major **22** | asserted by `provision.sh`; wrong major fails as opaque ESM errors later |
| **JDK 21** | 21 | **Keycloak only** — `kc.sh` runs `$JAVA_HOME/bin/java`. `sudo apt-get install -y openjdk-21-jdk-headless` |
| **Disk** | ~3 GB + headroom | repos ≈ 1.2 GB, runtime ≈ 337 MB, Keycloak ≈ 190 MB, plus caches |
| **RAM** | 7 GB total is the working minimum | per-JVM heap caps are set in `bin/env.sh` |

The JDK for CRD/PAS is provisioned for you (Temurin 17, checksum-verified,
into `runtime/jdk17`). You do not need a system JDK 17 — only Keycloak's 21.

**First run is slow — and that is the filesystem.** Cold provision 5–15 min;
first `up.sh --reset` (npm install + webpack) 20–40 min; warm runs 5–6 min.
Clone onto a normal ext4 filesystem; the original dev host sat on a 9p
Windows mount measured ~260× slower for small-file writes. `/tmp` is never
used (it was wiped once, taking the toolchain). Downloads land in
`runtime/downloads/`.

### Step 1 — system packages

```bash
sudo apt-get install -y openjdk-21-jdk-headless   # Keycloak only
# plus: git, curl, iproute2 (ss), python3, unzip
```

Node 22 via nvm/fnm/asdf — `provision.sh` asserts the major and prints what
it found.

### Step 1b — not running as root? Redirect three paths

`bin/env.sh` defaults Keycloak to `/opt/keycloak` and both caches to
`/root/.cache/davinci-mock/` — root-owned. If `id -u` is not `0`, export
these in the same shell that runs the scripts:

```bash
export KEYCLOAK_HOME="$HOME/.local/keycloak"
export GRADLE_USER_HOME="$HOME/.cache/gradle"
export VSAC_CACHE_DIR="$HOME/.cache/vsac"
```

Without these, provisioning dies with a bare `Permission denied` on the
Keycloak step, then again on the Gradle cache. `env.sh` appends the
load-bearing trailing slash to `VSAC_CACHE_DIR` itself. As root, skip this.

### Step 2 — provision the pinned inputs

```bash
./bin/provision.sh
./bin/provision.sh --check        # MUST report "all inputs present", exit 0
```

Clones all six upstream DaVinci repos at their exact 40-char SHAs,
checksum-verifies Temurin `17.0.20.1+1` and Maven `3.9.9`, installs Keycloak
`26.7.4`. Idempotent. `--check` is the real gate (a green `--check` proves
inputs are present — not that services start; those are different failures).

Three things `provision.sh` deliberately does **not** do (each has bitten
this project): it does not install Node or JDK 21 (it asserts them); it does
not place the **CDS-Library** where each service expects it (that logic lives
in `bin/up.sh`: CRD wants the whole library at
`repos/CRD/server/CDS-Library/`; PAS wants `PriorAuth/` only — never run
upstream's `embedCdsLibrary`, it `rm -rf`s and clones unpinned master); and
it does not trust `clone.sh`'s `[x] already cloned` answer for stale
checkouts (it re-verifies all six SHAs itself).

### Step 3 — seed value sets (optional; `up.sh` does it)

```bash
./bin/seed-valuesets.sh            # ~30 s cold, then a no-op
```

Rendering a questionnaire needs every value set in the library's
DataRequirements resolved; default seeds the 65 from public `tx.fhir.org` —
same terminology, no signup. Set `VSAC_API_KEY` in `bin/env.sh` to prefer
VSAC. `up.sh` runs this automatically before CRD boots and asserts the cache
is readable at the concatenated path CRD actually builds (see
[Known limitations](#known-limitations)).

---

## Run and verify

```bash
./bin/up.sh                      # start all six (container must be up in Path A)
./bin/up.sh --reset              # same, but wipe PAS H2 + DTR lowdb state first
```

`up.sh` starts in dependency order, builds the dtr/crg frontends once, seeds
value sets, refuses to start if any of the six ports is held, and runs
post-flight checks (dtr `/clients` non-empty, CRD advertises `order-sign-crd`,
the value-set cache readable at CRD's concatenated path, and the CRD
`hasDocNeededExtension` flag warmed so cards carry the DTR launch button).

**Do not trust the summary — probe independently:**

```bash
while read -r name port route; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$port$route" || echo 000)
  printf '  %-12s %s  %s  %s\n' "$name" "$port" "$code" "$route"
done <<'EOF'
keycloak     8180 /realms/BurdenReduction/.well-known/openid-configuration
ehr-shim     8080 /fhir/r4/metadata
crd          8090 /r4/cds-services
prior-auth   9015 /fhir/metadata
dtr          3005 /
crg          3001 /
EOF
```

All six must be `200` (note the paths: `/fhir/r4/metadata` on 8080,
`/fhir/metadata` on 9015, `/r4/cds-services` on 8090). A `404` on those
means you guessed the path, not that the service is down. `:3001` matters
most: crg serves its runtime URLs from `/env-config`, so if that is missing
the browser calls the wrong hosts even though `/` works.

Then verify with **both** drivers:

```bash
./bin/demo.sh                                 # 12 assertions, API only    -> 12/12
pip install playwright && playwright install chromium --with-deps   # once
python3 bin/e2e-browser.py                    # 14 assertions, real browser -> 14/14
```

`demo.sh` needs only `python3` + `curl`. `e2e-browser.py` is the only thing
needing Playwright; if it is missing the script says so and exits instead of
failing obscurely. Then open **<http://localhost:3001/>** and follow
[the browser walkthrough](#walkthrough-the-browser-path).

### Seed the IRIS side (Path A)

The image ships with the DaVinci demo patients. If you ever reset the
container or want to re-seed:

```bash
./bin/seed-iris.sh                             # loads pat013 & co. into IRIS
```

---

## Walkthrough: the browser path

The exact sequence `e2e-browser.py` drives — do it yourself:

1. Open **<http://localhost:3001/>**, click **`PATIENT SELECT`**; pick the
   **pat013 tile** (Vlad Quinton, 69, male), use *its own*
   `Select a request...` dropdown → **`E0607 (DeviceRequest) Home blood
   glucose monitor`**, then **`Click to select this patient`**.
2. **`SUBMIT TO CRD AND DISPLAY CARDS`** → wait 10–20 s while CRD evaluates
   rules → the card renders: *"Documentation Required — Complete
   HomeBloodGlucoseMonitorOrder in DTR."*

   ![the coverage card](docs/screenshots/01-crd-card.png)

3. Click the card button → a new tab opens on the **real Keycloak login
   page**. Sign in **`dtr` / `dtr-demo`**.

   ![Keycloak login](docs/screenshots/04-keycloak-login.png)

4. The *Home Blood Glucose Monitor Order* questionnaire renders with live
   value-set content (e.g. *"Type 2 diabetes mellitus with diabetic
   nephropathy — E11.21"*).

   ![the DTR questionnaire](docs/screenshots/03-dtr-questionnaire.png)

5. **Fill the form** (it arrives un-prefilled — see
   [Known limitations](#known-limitations)) → **`PROCEED TO PRIOR AUTH`** →
   dtr builds the `Claim`, swaps in a prior-auth panel → **`Submit`** (the
   only thing in the whole stack that POSTs from a browser).

Server-side, `logs/prior-auth.log`:

```
POST /Claim/$submit fhir+JSON
generateAndStoreClaimResponse(c37fe4f8…/0M987654001AZ, disposition: PENDING)
generateAndStoreClaimResponse(46204484…/0M987654001AZ, disposition: GRANTED)   # +15 s
```

The full nine-frame pass is in `docs/screenshots/e2e/`. The API path,
endpoints worth knowing (including CRD's `/metadata` and PAS's
`/actuator/health` being deliberate 404s), the `PENDING → GRANTED` poll, and
the `bundle-items.json`-vs-`bundle-prior-auth.json` fixture trap are all
documented in `TEST-FLOW.md`.

---

## Reference

### Stop and reset

```bash
./bin/down.sh          # stop all six (port sweep — it does not trust PID files)
./bin/down.sh --purge  # also delete PAS H2 + DTR lowdb state
```

`--purge` exists because PAS and DTR keep on-disk state; without it a
half-finished demo leaks Claims/registrations into the next run. `down.sh`
sweeps the six ports and verifies ownership (JVM daemon trees outlive their
recorded PID), and leaves unrelated services — e.g. a Next.js app on `:3000`
— alone. If PAS debug tables come back with 0 rows, a zombie PAS holds the
H2 file: `down.sh --purge && up.sh --reset`.

### Reaching it from another machine

All six services bind `0.0.0.0`; `env.sh` adds every global IPv4 to the CORS
allow-list. The browser decides which host to call, so advertise it:

```bash
./bin/up.sh                        # default: advertise localhost
ADVERTISE_HOST=192.168.1.50 ./bin/up.sh   # LAN mode
```

`ADVERTISE_HOST` also feeds `REACT_APP_INITIAL_CLIENT` — the SMART `iss` the
UI sends must equal the client name dtr registered, so the coupling is
load-bearing. In LAN mode, add your own address to the Keycloak client's
redirect URIs (the realm ships `localhost`/`127.0.0.1`/`192.0.2.10` by
design — it never bakes in a private IP). And note the prior-auth panel
targets the **public** PAS (`prior-auth.davinci.hl7.org`) on any non-
localhost origin; the endpoint field is editable, and `e2e-browser.py`
overwrites it with the page's own host — a manual LAN walkthrough must do
that by hand. Nothing in the stack opens a firewall port; that is your job:
allow inbound 3001, 3005, 8080, 8090, 9015 for the specific subnet.

### Credentials — the complete inventory

**None are needed.** Everything the stack authenticates against is public
upstream code or throwaway values that ship in this repo:

| What | Value | Action needed |
|---|---|---|
| Keycloak admin | `admin` / `admin` | none |
| Keycloak demo user | `dtr` / `dtr-demo` | none — `e2e-browser.py` types it |
| Keycloak client secret | `#replaceMe#` | literal upstream placeholder; nothing in the stack authenticates to Keycloak |
| PAS FHIR client | none | runs `BYPASS_AUTH=true`, issues its own token |
| IRIS OAuth client | auto-generated id/secret in `bin/env.sh` | created inside the image; only the ehr-shim uses it |

Why no credentials work: the two services that could demand them are
configured not to (PAS `BYPASS_AUTH=true`; CRD `use_oauth: false` +
`checkJwt: false`). **Keycloak exists for one reason:** the DTR launch does a
real SMART/OIDC redirect through a login page, so the browser path is
genuinely end-to-end. The only external fetches are the six public upstream
repos and their dependencies, pinned to exact SHAs in `versions.lock`.

> If a script ever stops you asking for something not in that table, treat
> it as a bug in the script, not a missing input.

### Pinned versions and pin discipline

`versions.lock` **is** the run version. Editing a SHA is a change of run
version — re-run both drivers, then tag. The scheme is one annotated tag
`run-YYYY-MM-DD`, never a branch, never moved once published (the
`run-2026-09-27` tag was deleted during the pre-publication scrub rather
than re-pointed; nothing in this tree references it). Key pins: six
`HL7-DaVinci/*` repos at exact SHAs, Temurin `17.0.20.1+1` (**not** `+8` —
upstream ships both), Maven `3.9.9`, Keycloak `26.7.4`, Node major 22, PAS
decision timer `DELAY=15000` ms.

The minimum that has to stay green for a release to be a run version:

```bash
./bin/up.sh --reset && ./bin/demo.sh           # 12/12
python3 bin/e2e-browser.py                     # 14/14
```

### Security note

**This is a demonstration, not a deployment** — deliberately not hardened:

- All six ports bind `0.0.0.0`, including a mock FHIR server and a PAS that
  will adjudicate a claim from anyone who can reach it. Your host firewall is
  the only control. Do not expose this stack to an untrusted network.
- The Keycloak credentials are published deliberately (`admin`/`admin`,
  `dtr`/`dtr-demo`). Do not reuse them anywhere.
- All patient data is synthetic. Do not paste real data into `fixtures/` or
  a screenshot.
- The scripts are a working recipe for an unauthenticated FHIR server — a
  different risk class from ordinary source code. Read `bin/` before you run
  it. See `SECURITY.md` for what is *not* a finding and how to report.

---

## Known limitations

- **The dtr questionnaire arrives un-prefilled.** CRD cannot resolve three
  CQL expression references (`ALTERNATIVE_THERAPY`,
  `RESULT_QuestionnaireAdditionalUri`, `RESULT_QuestionnairePARequestUri`)
  in `HomeBloodGlucoseMonitorRule` — an upstream library-loading gap. The
  form loads and is fillable; the browser run types what the API run gets
  from `bundle-items.json` for free.
- **One value set still 404s** in the browser console
  (`cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113762.1.4.1219.84`); it does
  not stop the flow.
- Without a `VSAC_API_KEY`, 67 value sets do not resolve and
  value-set-gated rules cannot fire — everything else works.
- The full prior-auth decision takes ~15 s by design (`DELAY=15000`).
- The IRIS image's `iris list` shows `state: warn` — benign (HealthShare
  failover context without a mirror partner).
- Linux only. And two silent traps guarded in `bin/`: `VSAC_CACHE_DIR` must
  keep its trailing slash (both file stores concatenate path + filename with
  no separator), and never seed an **unexpanded** value set
  (`expansion.contains == 0` yields a questionnaire with zero answer
  options). `seed-valuesets.sh` uses `$expand` and refuses to write unless
  `contains > 0`.

---

## Repository layout

```
bin/                      the run version
  env.sh                  single sourced env block: ports, paths, CORS, heaps, ADVERTISE_HOST
  provision.sh            build every input from versions.lock; --check verifies only
  clone.sh                one shallow clone at an exact SHA
  up.sh                   start 6 services, poll real readiness, post-flight checks
  down.sh                 stop + port sweep; --purge drops on-disk state
  demo.sh                 12-assertion API driver
  e2e-browser.py          14-assertion Playwright driver, browser → PAS decision
  seed-valuesets.sh       pre-seed the VSAC value-set cache from tx.fhir.org
  seed-iris.sh            seed the IRIS container with the DaVinci demo patients
  ehr-shim                Node proxy: mints IRIS bearer token, fronts 10.0.3.108:52774
  lxc-image-build.sh      MAINTAINER-side: build the distributable image from the container
  lxc-import.sh           end-user: download release parts, verify, extract, start (github mode)
versions.lock             every pin, machine-readable. This is the run version.
fixtures/                 demo hook payloads + the Keycloak realm (26 SMART scopes, dtr/dtr-demo)
docs/screenshots/         4 curated PNGs + a 9-frame e2e pass
LXC-DROPIN.md             the image runbook (fresh-Ubuntu path, IP contract, troubleshooting)
AGENTS.md                 playbook for an AI agent: provision, start, verify, report, stop
TEST-FLOW.md              the deep runbook — start here if this README is not enough
PLAN.md / SOURCES.md / investigation-log.md / GIT-PLAN.md / SESSION-NOTES.md
CONTRIBUTING.md / SECURITY.md / LICENSE
```

The image itself is built by `bin/lxc-image-build.sh` (safe-trim set: never
the WIJ, journals, `journal.log`, ssh keys, or `/var/log` dirs — each
deletion has put IRIS into single-user recovery) and published as release
assets on GitHub.

---

## Glossary

| Term | Meaning |
|---|---|
| **FHIR** | HL7's modern healthcare exchange standard — RESTful resources (Patient, Claim, Questionnaire…) over JSON/XML. R4 = 4.0.1, the current normative release |
| **SMART on FHIR** | the OAuth-based app-launch standard: an app in an EHR launches with a signed context (patient, encounter) |
| **CDS Hooks** | "cards" served at decision points (order entry) by calling an online service with FHIR context |
| **CRD / DTR / PAS** | the three DaVinci implementation guides: Coverage Requirements Discovery, Documentation Templates and Rules, Prior Authorization Support |
| **CQL** | Clinical Quality Language — the deterministic rule language DaVinci rules are written in |
| **Value set / VSAC** | named groups of codes used as rule inputs; VSAC is the US federal terminology authority |
| **Payer** | the insurer/plan that pays claims (US terminology) |
| **EHR / HIS** | Electronic Health Record / Hospital (Health) Information System |
| **IRIS for Health** | InterSystems' clinical data platform — FHIR repository, HL7 v2, multi-model storage |
| **OIDC** | OpenID Connect — the identity layer (login) SMART is built on |
| **LXC** | Linux Containers — lightweight system containers (the image format here) |

---

## Further reading

**The problem and the regulation**

- CMS-0057-F, *Advancing Interoperability and Improving Prior Authorization
  Processes* — final rule, January 2024 (patient/provider access + prior
  authorization FHIR APIs; 2027/2028 compliance dates). See the CMS fact
  sheet on cms.gov and `89 FR` docket CMS-0057-F.
- CMS-9115-F (2020) — the earlier interoperability and patient-access rule.
- [Prior authorization — Wikipedia](https://en.wikipedia.org/wiki/Prior_authorization):
  the cost/time statistics used above, with the original citations
  (Casalino et al., *Health Affairs* 2009; *JABFM* 2012; CAQH; Prime
  Therapeutics).

**The standards and the code**

- [HL7 DaVinci Project](https://confluence.hl7.org/display/AP/HL7+DaVinci+Project)
  — the project behind CRD/DTR/PAS.
- DaVinci CRD / DTR / PAS implementation guides (published on hl7.org/fhir/us):
  CRD (Coverage Requirements Discovery), DTR (Documentation Templates and
  Rules), PAS (Prior Authorization Support, STU 2).
- The six pinned upstream repos: `HL7-DaVinci/{CDS-Library,CRD,dtr,
  crd-request-generator,prior-auth,test-ehr}` — see `versions.lock`.

**IRIS for Health**

- [InterSystems IRIS for Health](https://www.intersystems.com/products/intersystems-iris-for-health/)
  — the platform; FHIR Services; Health Connect; OMOP.
- InterSystems Payer Services — marketed for CMS-0057/CMS-9115 compliance
  (the payer side of the same regulation).
- InterSystems success story: [Stanford Health Care — meeting healthcare AI
  performance demands with FHIR](https://www.intersystems.com/success-stories/meeting-stringent-healthcare-ai-performance-demands-with-fhir/).

**This repo's own docs**

- `LXC-DROPIN.md` — image runbook | `TEST-FLOW.md` — deep runbook |
  `AGENTS.md` — AI-agent playbook | `PLAN.md` / `investigation-log.md` /
  `SOURCES.md` — how it was built and what was learned | `CONTRIBUTING.md` /
  `SECURITY.md` — CI and security posture.

---

MIT — see [`LICENSE`](LICENSE). No upstream DaVinci code is redistributed
here: `bin/provision.sh` clones the upstream projects at pinned SHAs, so
their licences apply to them. The IRIS instance is InterSystems IRIS for
Health Community Edition (free for evaluation/development).