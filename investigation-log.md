# Investigation log

Raw findings, **2026-09-26 → 2026-09-27**. Kept so nobody re-derives the wrong answers — including
the places where this investigation was wrong and had to be corrected by running the software.

Plan lives in `PLAN.md`. Provenance in `SOURCES.md`. How to *run* the thing lives in `TEST-FLOW.md`.

---

## Evidence tiers

Read this before trusting anything below.

| Tier | Meaning | Applies to |
|---|---|---|
| **BOOT** | Service was started and observed serving traffic | test-ehr, CRD, **prior-auth (Phase 0)**, **dtr, crd-request-generator, keycloak (§4)** |
| **PARSE** | File fetched and parsed programmatically | realm JSON, PDF text, repo trees, GitHub API |
| **READ** | Config/Dockerfile/CI content read and reasoned about, **not** executed | — (none outstanding) |
| **RETIRED** | Investigated, then removed from scope | nothing currently |

**All six services are BOOT.** dtr, crd-request-generator and test-ehr were promoted READ → BOOT by
Phase 2 (2026-09-26) and the whole browser chain was then driven to a PAS decision in §4
(2026-09-27). There is no service left at READ.

**keycloak was RETIRED on 2026-09-26 and reinstated on 2026-09-27.** The retirement reasoning was
wrong, and §4 records exactly how: `use_oauth: false` does **not** make test-ehr's auth proxy
optional. Every API-level test passes without Keycloak because the order-sign hook never expands a
value set and never needs a token — so the stack looks completely healthy right up until a browser
clicks through, and then it fails on an empty `:8180`. A service can be load-bearing for one path
and irrelevant to every other.



---

## Corrections made during this investigation

### 1. Fabricated patient data (my error, caught by booting)

An intermediate research pass reported these test-ehr patients:

> `Tables, Bobby` / `Oster, William` / `Wilson, Ada` / `Quinton, Vlad` / `Roosevelt, Theodor`

**None of those surnames exist.** The actual `name.family` values are single letters. I had
pattern-matched the given name "William" into the surname "Oster". Verified by parsing all 121
seed files and querying the live database:

| id | family | given | birthDate | gender |
|---|---|---|---|---|
| `pat1234` | `T` | Bobby | 1996-12-23 | male |
| `pat015` | `O` | William | 2015-02-23 | male |
| `pat016` | `W` | Ada | 1976-02-23 | female |
| `pat013` | `Q` | Vlad | 1956-12-01 | male |
| `pat014` | `R` | Theodor | 1946-07-04 | male |

The source PDF's "Vlad Quinton (pat013)" is the same mangling, **upstream** — it is not a
transcription error on my part. `pat013` = family `Q`, given `Vlad`.

### 2. Seed count

First pass said 122 files / 34 Observations. Actual: **121 files, 33 Observations.** All 25
resource types match seed-to-database exactly.

### 3. "Bare id" seeding bug — not a bug

`DataInitializer.java:77` does `.setUrl(fhirResource.getIdElement().getValue())`, which looks like
it stores a bare id where a `Resource/id` is required. HAPI qualifies the parsed resource's
`IdType` at runtime, so it is spec-shaped. Observed in the log:

```
Adding resource to bundle: Patient-pat1234.json with URL: Patient/pat1234
```

### 4. Idempotence — initially "needs re-verification", now verified

Booted test-ehr **twice** against a persistent file-backed H2, so the second boot genuinely
re-seeded a populated database:

```
BOOT 1 (empty file DB)   Patient=5 Coverage=5 DeviceRequest=16 ServiceRequest=4 Observation=33 Condition=22
BOOT 2 (same file DB)    Patient=5 Coverage=5 DeviceRequest=16 ServiceRequest=4 Observation=33 Condition=22
```

No duplication, zero errors. **Switching test-ehr to a persistent database is safe.**

### 5. My `LOCALDB_PATH` advice was incomplete until measured

I initially recommended setting `LOCALDB_PATH` without mentioning the trailing slash. Measuring
it revealed the slash is load-bearing. See below — this is the worst failure mode in the stack.

### 6. My `LAUNCHURL` recommendation was wrong

I first recommended a relative `LAUNCHURL=/smart/launch.html`. That produces a 404. The working
form is absolute. See below.

### 7. `PriorAuth/` CDS-Library conclusion was partly moot

I flagged that `CDS-Library/PriorAuth/` does not load under CRD. True, but it does not affect the
plan: CRD uses `CRD-DTR/` for its own rules and PAS embeds `PriorAuth/` for its own. Noted as an
open item rather than a blocker.

---

## test-ehr (BOOT)

**Strongest evidence in the whole investigation.** Booted, seeded, served traffic, twice.

- Maven project (`pom.xml`). `gradle loadData` from the PDF does not exist.
- **Self-seeds on boot** — `Initializing data` / `Loading resources from directory: seed-data`,
  at `restartedMain`, completing before the port accepts traffic. No manual load step.
- 121 seed files, 25 resource types:

```
Observation 33   Condition 22   DeviceRequest 16   Encounter 6
Patient 5  Coverage 5  Practitioner 5  ServiceRequest 4
AllergyIntolerance 3  MedicationStatement 3  Organization 2
Medication 2  MedicationRequest 2  Questionnaire 2
CarePlan 1  CareTeam 1  ClinicalImpression 1  Consent 1  Goal 1
Location 1  MedicationDispense 1  PractitionerRole 1  Procedure 1
Provenance 1  Task 1                                     = 121
```

- **Both base paths work:** `/test-ehr/r4/Patient/pat015` and `/fhir/Patient/pat015` → 200.
- `SPRING_DATASOURCE_URL` defaults to `jdbc:h2:mem:test_mem`. Making it persistent is safe (§4).
- No env vars needed to boot.

---

## CRD (BOOT)

Booted, loaded 126 rules, returned a live card with a working CMS PDF link and an embedded DTR
link. **Needs no FHIR server, no Keycloak, no database.**

### Findings

**`LOCALDB_PATH` trailing slash is load-bearing.** `CommonFileStore.java:630`:
```java
String cqlFileLocation = localPath + topic + "/" + fhirVersion + "/files/";
```
No separator inserted. Measured:

| `localDb.path` | rules loaded | CQL misses | fatal |
|---|---|---|---|
| `.../CRD-DTR` | **2** | 52 | no |
| `.../CRD-DTR/` | **126** | 0 | no |

Does not crash. Starts, advertises all six CDS services, answers HTTP 200, evaluates nothing. The
shipped default `CDS-Library/CRD-DTR/` has the slash, so the image is fine.

**`/actuator/health` is permanently DOWN:**
```json
{"status":"DOWN","components":{
  "db":{"status":"UP"},"diskSpace":{"status":"UP"},"ping":{"status":"UP"},
  "elasticsearch":{"status":"DOWN","details":{"error":"java.net.ConnectException: Connection refused"}}}}
```
Inherits HAPI's Elasticsearch contributor but runs on H2. Observed **serving 126 rules and correct
cards while reporting DOWN**. `MANAGEMENT_HEALTH_ELASTICSEARCH_ENABLED=false` → UP, with rules
still loaded.

**`LAUNCHURL` must be absolute.** `CdsService.java:492-499` branches on `isAbsolute()`; the
relative branch prepends `applicationBaseUrl.getFile()` (`/fhir/r4`):

```
LAUNCHURL=/smart/launch.html
  -> card link: http://localhost:8090/fhir/r4/smart/launch.html   HTTP 404
  -> /smart/launch.html                                          HTTP 200
LAUNCHURL=http://localhost:8090/smart/launch.html
  -> card link: http://localhost:8090/smart/launch.html          HTTP 200
```

Also `appendParamsToSmartLaunchUrl: false` (`application.yml:53`) — the DTR link gets no
`iss`/`patientId`/`template`, so the questionnaire opens contextless.

**Missing CDS-Library is a hard exit:**
```
FATAL ERROR: Failed to reload from folder: file path CDS-Library/CRD-DTR/ does not exist
```
Immediate `System.exit(1)`, no listener.

**VSAC absent is non-fatal.** `VSAC_API_KEY not found in environment variables` → ERROR log only,
126 rules still loaded.

**`application-docker.yml` is dead.** Never loaded; `LocalDb` has no `rules`/`fhirArtifacts`
fields.

### A working request (BOOT, HTTP 200, live card)

Built from `DeviceRequest/devreq037` against seed data (E0607, `pat013`/`cov013`):

> **Resource bodies below are elided** — the real request carries the full
> `DeviceRequest/devreq037`, the matching `Coverage/cov013` and `Patient/pat013` bundles. Fetch
> them from test-ehr's seed data. The *shape* is what matters here.

```json
{"hook":"order-sign","hookInstance":"e2e-mock-001",
 "fhirServer":"http://localhost:8080/test-ehr/r4/",
 "context":{"patientId":"pat013",
   "draftOrders":{"resourceType":"Bundle","type":"collection","entry":[{"resource":{}}]}},
 "prefetch":{
   "deviceRequestBundle":{"resourceType":"Bundle","type":"collection","entry":[]},
   "coverageBundle":{"resourceType":"Bundle","type":"collection","entry":[]},
   "patient":{"resourceType":"Bundle","type":"collection","entry":[]}}}
```

→ `HTTP 200`, card `Home Blood Glucose Monitor: Documentation Required.`

Two gotchas encoded here:
- `context.draftOrders` must be a **`Bundle`**, not a bare resource. A bare `DeviceRequest` → 400.
- Discovery declares four prefetch keys — `serviceRequestBundle`, `medicationRequestBundle`,
  `coverageBundle`, `deviceRequestBundle`. Supplying only some is tolerated; supplying none
  yields the card "Unable to (pre)fetch any supported bundles".

**Upstream's own test fixture is broken.** `server/src/test/resources/requests/deviceRequestPrefetch.json`
returns "Unable to (pre)fetch any supported bundles" because it populates only
`deviceRequestBundle` while discovery declares four. Do not use it as a model.

---

## dtr (READ)

**Production image, not a dev server.** `node:22-alpine` both stages, `npm run buildFrontendProd`
then `npm ci --only=production`, `CMD ["node","./bin/prod"]`. The PDF's `npm start` maps to
`nodemon` + `webpack --watch` and is **never used by the image**.

- **The PDF's `webpack.config.dev.js` step is obsolete.** That file does not exist, there is no
  `https` boolean left, and `bin/www` unconditionally does `http.createServer` — HTTP only, by
  construction. No TLS to terminate.
- **Client registration is pre-seedable:** `REACT_APP_INITIAL_CLIENT=<iss>::<client_id>`. Format is
  double-colon separated. The **default is already** `http://localhost:8080/test-ehr/r4::app-login`,
  so if the EHR `iss` matches, the PDF's manual `/register` step is a no-op. `bin/www` performs a
  self-`PUT` to `/clients` on boot.
  Trap: `bin/template` reads `process.env.INITIAL_CLIENT` (no `REACT_APP_` prefix). Different var.
- **Registration does not survive recreation.** Storage is lowdb → `databaseData/db.json`
  (CWD-relative). `docker restart` survives it; `compose down`/`up --force-recreate` does not.
  Its `docker-compose.yml` declares **no volume**. The image is already prepared for a mount
  (copies `/app/databaseData`, healthcheck hits `GET /clients`).
- **No Keycloak code at all** — zero `keycloak` references in the repo. Realm/client must be
  pre-seeded externally, exactly as the PDF says.
- **Undeclared dependency:** `bin/www` does `import debug from "debug"`, but `debug` is not in
  `package.json` — resolves only via transitive hoisting. One dependency-graph change from an
  unbootable image, since production runs `npm ci --only=production`.
- Readme is stale: references `hspc/davinci-dtr` (real tag is `hlseven/davinci-dtr:latest`) and
  `VERSION='Prod'`/`VERSION='Template'` flags the Dockerfile no longer reads.
- Its `docker-compose.yml` is 110 bytes, one service, and does not join any external network.

---

## crd-request-generator (READ)

- **Production image.** `node:22-alpine` both stages, `CMD ["npm","run","production"]` →
  `NODE_ENV=production node server.js`, serving built `index.html`.
- **`npm start` is dangerous here.** `isDevelopment = process.env.NODE_ENV !== 'production'`, so
  `npm start` triggers in-process webpack + HMR on every boot.
- **Defect:** the Dockerfile does `RUN echo '{}' > db.json`, but `server.js` only seeds
  `{"public_keys": []}` if the file is **absent**:
  ```js
  if (!fs.existsSync(DATA_FILE)) { fs.writeFileSync(DATA_FILE, JSON.stringify({ public_keys: [] }, null, 2)); }
  ```
  So `data.public_keys` is `undefined` and `POST /public_keys` throws → 500. Bind-mount a
  correct `db.json`.
- **Config precedence** (`src/util/data.js`): localStorage → runtime env var → config file.
  Runtime vars arrive via `GET /env-config`, fetched at boot and awaited before render.
- **Nine configurable keys**, all consumed **in the browser**:

| target | env var | default |
|---|---|---|
| EHR / FHIR server | `REACT_APP_EHR_SERVER` | `http://localhost:8080/test-ehr/r4` |
| CRD CDS Hooks base | `REACT_APP_CDS_SERVICE` | `http://localhost:8090/r4/cds-services` |
| order-select hook | `REACT_APP_ORDER_SELECT` | `order-select-crd` |
| order-sign hook | `REACT_APP_ORDER_SIGN` | `order-sign-crd` |
| DTR launch | `REACT_APP_LAUNCH_URL` | `http://localhost:3005/launch` |
| form expiry days | `REACT_APP_FORM_EXPIRATION_DAYS` | `30` |
| alt-therapy cards | `REACT_APP_ALTERNATIVE_THERAPY` | `true` |
| JWT `jku` public keys | `REACT_APP_PUBLIC_KEYS` | `http://localhost:3000/public_keys` |
| OAuth client id | `REACT_APP_CLIENT` | `app-login` |

- **`.env.example` is wrong about the order hooks.** It ships full URLs, but
  `RequestBuilder.js` **concatenates** them onto the CDS base:
  ```js
  cdsUrl = cdsUrl + "/" + this.state.orderSign;
  ```
  Copying it verbatim yields `.../r4/cds-services/https://localhost:8090/order-select`. Must be
  bare segments. Treat `.env.example` as unreliable.
- **No PAS endpoint exists in this repo.** PA is reached only indirectly: CRD card → SMART link →
  `REACT_APP_LAUNCH_URL` → DTR. `REACT_APP_LAUNCH_URL` is the only seam.
- Dead keys in `properties.json`: `server`, `user`, `password` — not in any `getConfigValue`
  mapping. `user`/`password` are leftovers from basic auth; `auth.js` now does SMART OAuth with
  PKCE S256.
- Because all nine values are browser-resolved, **compose service names will not work** without a
  proxy presenting one hostname. Fine for a same-host demo with published ports.
- CI builds the image but only publishes to `smalho01234/…`. **No HL7-org image exists.** No
  `docker-compose.yml` in the repo.

---

## prior-auth (READ → BOOT)

> Originally READ. **Promoted to BOOT by Phase 0** — see §0 at the end of this file for the
> executed evidence. The analysis below is the pre-Phase-0 reading and is retained because it is
> still accurate for everything except the submit path.

**PAS is a leaf.** It receives a finished `Bundle` and returns a `ClaimResponse`. There is **no
CRD integration and no upstream EHR integration** on `master` — `config.properties` has three
keys and no endpoint. `PriorAuthRule.computeDisposition()` runs CQL entirely against the submitted
Bundle. The only outbound HTTP in the whole application is `AuthEndpoint.getJwks()`.

- **Database:** H2, embedded, file-backed at `jdbc:h2:./databaseData/database;DB_CLOSE_DELAY=-1`.
  Tables `Bundle, Claim, ClaimResponse, ClaimItem, Subscription, Rules, Audit, Client`.
  `CreateDatabase.sql` is `CREATE TABLE IF NOT EXISTS` — idempotent. Queries are built by string
  concatenation.
- **Four env vars, read via `System.getenv`, no Spring binding:** `TOKEN_BASE_URI`, `BYPASS_AUTH`,
  `debug`, `DELAY` (default 15000 ms — controls pended-claim auto-release; useful for
  deterministic demo timing).
- `TOKEN_BASE_URI` affects **only the advertised OAuth URIs** in the CapabilityStatement, not
  where PAS listens. Falls back to `X-Forwarded-Proto`/`X-Forwarded-Host`.
- **Hardcoded admin token in git**, no override:
  `AuthUtils.java` → `private static final String ADMIN_TOKEN = "<redacted>";`
  A request with `Authorization: Bearer <that>` bypasses all auth. The literal is
  **not reproduced here on purpose** — it is upstream's secret, not ours, and
  republishing it in a third repository is a disclosure we get no credit for. Read it
  out of the pinned `repos/prior-auth` checkout, or just note that it exists: the
  finding is the *absence of an override*, which is the part that matters.
- **Debug endpoints** (gated on `App.isDebugModeEnabled()`): `POST /fhir/debug/PopulateDatabaseTestData`
  (6 bundles + 2 ClaimItems + 2 Clients; timestamps in **2200** so seeded data is identifiable),
  `POST /fhir/debug/PopulateRules`, `GET /fhir/debug/ReleaseClaim?identifier=`,
  `POST /fhir/debug/Convert`, `ConvertAll`, `GET /fhir/debug/{table}`, `POST /fhir/$expunge`.
- **`-Pdebug` is not app debug mode.** It sets a Gradle property enabling the JDWP agent
  (port 9016). App debug needs env `debug=true` or `--args='debug'`. The prod image therefore
  ships with seeding **disabled**.
- **The prod image runs `gradle bootRun` at container start** rather than shipping a built
  artifact — slow boot, and Gradle must exist in the runtime image.
- **CWD-dependent:** `config.properties`, `./databaseData/`, `src/main/resources/style.html`,
  `CreateDatabase.sql`, `CDS-Library/PriorAuth/`. The app only works if CWD is the repo root.
- **No healthcheck anywhere.** No `spring-boot-starter-actuator`, so no `/actuator/health`.
  Closest usable probe: `GET /fhir/metadata` (unauthenticated) — but it lazily builds the
  CapabilityStatement **and writes an `AuditEvent` row on every call**.
- `DockerLocalSetupGuide.md` itself warns: *"if not enough resources are provided, you may notice
  containers unexpectedly crashing."*
- Demo credentials in the guide: `alice` / `alice`.
- **Useful fixtures for a harness:** `src/test/resources/bundle-prior-auth.json` (21 KB, the
  canonical one), `bundle-dtr.json`, `bundle-items.json`, `bundle-request.json`,
  `questionnaresponse-dtr.json`, `cds-hook-order-review.json`,
  `subscription-{resthook,websocket,email}.json`. Plus `PriorAuth.postman_collection.json` (330 KB).
- **README "Configuration Notes" is stale** — describes `src/components/PriorAuth` and a
  LogicaHealth `tokenUri` in `Metadata.java` that do not exist on `master`. Belongs to the `dev`
  branch era.

---

## Keycloak (PARSE)

- Compose image is **pre-Quarkus (≤16.x)**, inferred from the volume path
  `/opt/jboss/keycloak/standalone/data/` and the `KEYCLOAK_IMPORT` env var — a custom-image
  convention, not stock Keycloak (stock uses `--import-realm` on start).
- Realm JSON: **9 clients, 0 users.** The `alice` user must be created by hand.
- `app-login` is `publicClient: true` with redirect `http://localhost:8080/*`, `webOrigins: ['*']`.
  Works for a same-host demo; breaks for any other origin.
- `DB_VENDOR=h2`, `KEYCLOAK_USER=admin`, `KEYCLOAK_PASSWORD=admin` — demo-grade credentials, fine
  for this purpose.

---

## §0 Phase 0 — prior-auth (BOOT)

Run natively. **No container runtime was available** (no docker, podman, nerdctl or buildah), and
per the user's instruction none was to be used. A non-invasive Temurin 17 tarball was unpacked to
`/tmp/davinci-scratch/jdk17` rather than installing a system JDK.

### Environment gotcha: system Gradle is 4.4.1

```
FAILURE: Build failed with an exception.
* Where: Build file '/tmp/davinci-scratch/pa/build.gradle' line: 6
* What went wrong:
> Could not set unknown property 'allowInsecureProtocol' for object of type
  org.gradle.api.internal.artifacts.repositories.DefaultMavenArtifactRepository.
```

`build.gradle:6` declares an `http://repo.jenkins-ci.org/releases/` maven repo with
`allowInsecureProtocol = true`, which needs Gradle 6+. The wrapper (8.14.2) is **mandatory**.
Note: I initially misread a truncated `gradle --version` and reported the system Gradle as
8.14.2; it is 4.4.1.

### Setup

```
git clone https://github.com/HL7-DaVinci/prior-auth.git
git checkout 848f28c11d8efb4e253b70cfbbc485acf9acd1a0     # master, 2026-07-22
./gradlew embedCdsLibrary        # clones CDS-Library@master
BYPASS_AUTH=true debug=true TOKEN_BASE_URI=http://localhost:9015 \
  ./gradlew bootRun --args='debug'
```

Startup: **3.6 seconds** ("Started App in 3.566 seconds (JVM running for 5.509)"), listening on
9015. Note it runs under devtools `restartedMain` because
`developmentOnly("org.springframework.boot:spring-boot-devtools")` is on the bootRun classpath.

### `CDS-Library/PriorAuth/` structure — confirmed correct for PAS

```
CDS-Library/PriorAuth/{HomeBloodGlucoseMonitor,HomeOxygenTherapy,HospitalBeds,ImmunosuppressiveDrugs}/
    <Topic>/                      <- flat
        <Topic>PriorAuthRule.cql
        <Topic>PriorAuthRule.elm.xml
        TopicMetadata.json
```

4 topics, each with `TopicMetadata.json` and a **pre-compiled** `.elm.xml`. This is exactly what
`PriorAuthRule.populateRulesTable()` expects, and the Rules table populated on boot
(`Database::write(Rules, { … })` for cpt/hcpcs/rxnorm/sct code systems).

This is the **flat** layout that CRD *cannot* read — CRD wants `<topic>/R4/files/<rule>.cql`.
Confirms the earlier finding that the two consumers need different CDS-Library shapes, and that
PAS is unaffected.

### `$submit` works locally — the 2022 note is obsolete

```
POST /fhir/Claim/$submit   (bundle-prior-auth.json, 21532 bytes, 15 entries)
  -> HTTP 201 Created | 3570 bytes | 0.17s
```

Response: `Bundle` profiled `profile-pas-response-bundle`, containing a `ClaimResponse` profiled
`profile-claimresponse`:

| field | value |
|---|---|
| status | `active` |
| outcome | `queued` |
| disposition | `Pending` |
| use | `preauthorization` |
| preAuthRef | `e45c42fa-fc8e-45e1-8a57-47c64790cf0a` |
| requestor | `Practitioner/pra1234` |
| patient | `Patient/pat013` |

Also echoed back: `Patient/pat013`, `Practitioner/pra1234`, `Organization/org1234`,
`PractitionerRole/prarol1234`.

### The CQL rules engine really runs

Both submissions went PENDING → GRANTED exactly 15s apart, matching `DELAY` (default 15000ms):

```
12:14:41.632  [nio-9015-exec-2]  generateAndStoreClaimResponse(e45c42fa…/pat013, disposition: PENDING, status: ACTIVE)
12:14:56.662  [Timer-0]           generateAndStoreClaimResponse(663f8786…/pat013, disposition: GRANTED, status: ACTIVE)
12:16:23.308  [nio-9015-exec-10] generateAndStoreClaimResponse(6c914b41…/98765400001AZ, disposition: PENDING, status: ACTIVE)
12:16:38.412  [Timer-1]           generateAndStoreClaimResponse(46913083…/98765400001AZ, disposition: GRANTED, status: ACTIVE)
```

`Timer-0`/`Timer-1` is `ClaimEndpoint.schedulePendedClaimUpdate()` firing on the DELAY timer. The
timer reads the pended Claim and writes a *new* ClaimResponse carrying the final disposition —
so the pended-claim ID and the final ID differ. Worth knowing when correlating.

### "Pending" is the fixture, not a bug

`bundle-prior-auth.json`'s Claim has **0 items**. The log states the cause outright:

```
WARN ClaimResponseFactory::determineDisposition:Request had no items to compute
     disposition from. Returning in pended by default
```

### Fixture comparison — pick `bundle-items.json` for the demo

| fixture | bytes | entries | Claim items | result |
|---|---|---|---|---|
| `bundle-prior-auth.json` | 21532 | 15 | **0** | 201, Pending (fallback path) |
| **`bundle-items.json`** | — | 16 | **2** | 201, Pending (rules path) + per-item extensions |
| `bundle-dtr.json` | — | 9 | none | no Claim at all |
| `bundle-request.json` | — | 12 | 0 | — |

`bundle-items.json` produced two `ClaimResponse.item` entries, each carrying:

```
http://hl7.org/fhir/us/davinci-pas/StructureDefinition/extension-itemPreAuthIssueDate  -> 2026-09-26
http://hl7.org/fhir/us/davinci-pas/StructureDefinition/extension-authorizationNumber   -> 8c540a8f…
```

Those authorization numbers render in the CRG UI, so this fixture demos far better.

### Read-back: there is no clean endpoint

| attempt | result |
|---|---|
| `GET /fhir/ClaimResponse/{id}` | 404 — no plain read endpoint |
| `GET /fhir/ClaimResponse/$inquire?identifier=` | 404 — wrong verb |
| `POST /fhir/ClaimResponse/$inquire` | 404 — wrong class |
| `POST /fhir/Claim/$inquire` | reaches the app, then `OperationOutcome` "Unable to process" |

`ClaimInquiryEndpoint` is `@RequestMapping("/Claim")` with `@PostMapping("/$inquire")`. Its
contract, from the source:

```java
if (claimInq.hasProvider() && claimInq.hasInsurer()
        && (FhirUtils.getPatientIdentifierFromBundle(bundle) != null)) { … }
```

so the inquiry Bundle needs a first-entry `Claim` with **both** `provider` and `insurer`, and a
`Patient` carrying an **`identifier`** — a bare `patient.reference` is rejected:

```
ERROR ClaimInquiryEndpoint::InquiryOperation: Required elements were not found in inquiry Bundle:null
```

Note `bundle-prior-auth.json`'s Claim has `provider` but **no `insurer`**, so the stored claims
don't match a naive inquiry either.

**For Phase 4 assertions use `GET /fhir/debug/ClaimResponse`** — returns an HTML table of the
whole table, HTTP 200, trivially parseable. Verified populated: 5 Claims, 9 ClaimResponses.

### Endpoint map (class-level `@RequestMapping`)

| path | class |
|---|---|
| `/fhir/Claim` | `ClaimEndpoint` (`$submit`, `$inquire`) |
| `/fhir/ClaimResponse` | `ClaimResponseEndpoint` |
| `/fhir/Bundle` | `BundleEndpoint` |
| `/fhir/Subscription` | `SubscriptionEndpoint` |
| `/fhir/metadata` | `Metadata` — unauthenticated |
| `/fhir/debug` | `DebugEndpoint` |
| `/fhir/Log` | `LogEndpoint` |
| `/fhir/auth` | `AuthEndpoint` |
| `/.well-known` | `WellKnownEndpoint` |

Confirms **PAS implements its own OAuth** (`/auth/register`, `/auth/token`) against an H2
`Client` table — it does not use Keycloak. Keycloak exists only for test-ehr.

### Fix #7 validated

With `debug=true` as an env var (not `-Pdebug`):

```
POST /fhir/debug/PopulateDatabaseTestData -> HTTP 200
POST /fhir/debug/PopulateRules            -> HTTP 200
```

### Benign startup noise

```
org.h2.jdbc.JdbcSQLIntegrityConstraintViolationException: Unique index or primary key violation:
"PUBLIC.PRIMARY_KEY_4 ON PUBLIC.RULES(SYSTEM, CODE) VALUES 1"
    at org.hl7.davinci.rules.PriorAuthRule.populateRulesTable(PriorAuthRule.java:139)
```

Devtools' double `restartedMain` re-populates the Rules table. Non-fatal — rules still load and
dispositions still compute. Ignore, or build without devtools.

---

## §1 Phase 1 — test-ehr (READ → BOOT), and the `code[x]` choice-type trap

Run natively with Maven 3.9.9 under **JDK 17** (`pom.xml` sets `<java.version>17</java.version>`,
so the system Java 21 is wrong for it). `packaging=war`, `finalName=ROOT`, H2 in-memory
(`jdbc:h2:mem:test_mem`) — no external database, and it self-seeds from `initial-data: seed-data`.

| probe | result |
|---|---|
| `GET :8080/fhir/metadata` | 200 |
| `GET :8080/test-ehr/r4/metadata` | 200 (the README's path also works) |
| `GET :8080/fhir/actuator/health` | 200 |
| readiness | **~25–40 s** from cold |

Seed data lands correctly: 5 Patients, 5 Coverages, 5 Practitioners, 2 Organizations,
1 PractitionerRole. `pat013` = **Vlad Alan Nestor Quinton**, male, 1956-12-01.

**The demo fixture is `DeviceRequest/devreq037`** — code `E0607` (Home blood glucose monitor),
`subject: Patient/pat013`, `insurance: Coverage/cov013`, requester `Practitioner/pra-hfairchild`.
Source: `seed-data/o2john_04__device-requestC.json`. This confirms the plan's `pat013` + `E0607`
claim. (The other E0607 seed, `devreq236`, belongs to `pat016` Ada Lovelace Wilson — not the demo
patient.) pat013 has 4 DeviceRequests: `devreq013`, `devreq033`, `devreq037` (E0607),
`devreq-013-e0250`.

### Trap: `DeviceRequest.code[x]` is a *choice type* — do not "fix" it to `code`

**Correction.** I initially read the seed data's `codeCodeableConcept` as a typo, renamed it to
`code` in all 16 files, and logged the result as a test-ehr defect. That was wrong, twice over.
`git checkout -- src/main/resources/seed-data` restored it. The upstream data was correct.

`DeviceRequest.code` is declared `code[x]` in R4 — a choice of `Reference(Device) | CodeableConcept`:

```
DeviceRequest.code[x] | Type: Reference(Device)|CodeableConcept
```

HAPI models the field as the abstract base type, which is why the generated accessor is
`getCodeCodeableConcept()` and the field javadoc reads `public Type getCode()`. For a
CodeableConcept-valued choice element the JSON name is **`<base><TypeName>` =
`codeCodeableConcept`**, exactly as the seed data and CRD both use it.

The trap is that HAPI's `LenientErrorHandler` **round-trips unrecognised elements**, so a GET of
`codeCodeableConcept` looks perfectly healthy. Renaming it to `code` is what breaks it — `code` is
not a valid JSON name for a choice element, so HAPI then reports it as unknown and drops it:

```
WARN ca.uhn.fhir.parser.LenientErrorHandler : Unknown element 'code' found while parsing   (×20, one per DeviceRequest)
```

Proven directly against CRD's own resolved classpath (`hapi-fhir-base 6.10.5` +
`org.hl7.fhir.r4 6.5.18`), parsing a DeviceRequest and reading `getCodeCodeableConcept()`:

| JSON name in the resource | `getCoding().size()` |
|---|---|
| `codeCodeableConcept` | **1** ✅ |
| `code` | 0 ❌ |
| `code` + `codeCodeableConcept` | 1 ✅ |

Identical result whether the DeviceRequest is parsed standalone or nested inside a Bundle, and
whether `ServiceRequest` (whose `code` is a plain `CodeableConcept`, so JSON name really is `code`)
is used as the control. `ServiceRequest.code` round-trips fine, which is what made the original
diagnosis look plausible.

The two warnings that remain on clean, unmodified seed data are genuine upstream typos, both
harmless and neither on the demo path:

| count | warning | source |
|---|---|---|
| 1 | `Unknown element 'organization '` (trailing space in the key) | `6. practitioner-role.json` |
| 1 | `Unknown element 'intent'` | one non-DeviceRequest seed |

This cost a full debugging cycle, so it is recorded prominently: **`codeCodeableConcept` is
correct. Leave it alone.**

### Two more test-ehr behaviours worth knowing

- **Creates are silently discarded.** `POST /Patient/p-probe-1` → **201**, then
  `GET /Patient/p-probe-1` → **404**. A `PUT` to the same URL persists. So the seed data is the
  only reliable way to get data in, and any demo-time write must use PUT, not POST. A 201 that
  leaves nothing behind is exactly the kind of thing that wastes an afternoon.
- **Editing seed data needs three copies patched**, because `spring-boot:run` serves the exploded
  war: `src/main/resources/seed-data/`, `target/classes/seed-data/`, and
  `target/ROOT/WEB-INF/classes/seed-data/`. Patching only `src/` silently does nothing. For
  reproducibility `up.sh` should `mvn clean` rather than rely on incremental copies.

---


**Every upstream default is `localhost:PORT` on purpose** — test-ehr 8080, CRD 8090, DTR 3005,
PAS 9015, crd-request-generator 3000/3001, (keycloak 8180, dropped). Upstream only ever supported
single-host. For a same-host demo,

published ports work untouched and **no reverse proxy is needed**. Adding one is the *riskier*
choice: it introduces path routing and redirect-URI rewriting on top of a stack already dense with
config. (This reversed an earlier recommendation in this investigation.)

**The PDF is a competent 2020-era manual whose stated prerequisites are below the current
minimums** — not merely stale. Java 8/11 cannot build CRD or PAS; Node 12 cannot run dtr or CRG;
Gradle 5.x cannot build PAS. The from-source path is dead. The upstream Docker path was the other
live one, and the PDF never mentions it.

**`prior-auth/docker-compose.yml` is a complete inventory of the upstream stack** — all 9
services, their ports, and their wiring. Used here as *documentation only* (it is where §2's
authoritative port map comes from), never executed: no container runtime is available and none is
wanted. The native bring-up is a supervisor over 5 processes, and it is a smaller job than the
compose file looked, because **Keycloak turned out to be dead weight** — `use_oauth: false` in
test-ehr, `checkJwt: false` in CRD, and PAS has its own `/auth`. Dropping it removes the only
service that needed an EOL WildFly distro and a second JDK.

**Two doc errors worth carrying forward.** The DTR repo is `HL7-DaVinci/dtr`, not
`hlseven/davinci-dtr` (which 404s). And **3000 is crd-request-generator, not CRG** — there is no
separate CRG service in the compose; earlier drafts conflated the Coverage Requirements Guide with
the request-generator UI. Both would have cost real time.


---

## §2 Phase 1 — CRD (BOOT) and the first end-to-end coverage-requirements card

CRD is a **Spring Boot** app (not Quarkus), Tomcat on `:8090`, context path `''`. Started with
`./gradlew server:bootRun` under **JDK 17**; ready in **~20 s** warm, ~90 s cold.

### The plan's readiness probe is wrong

`PLAN.md` said `GET :8090/metadata`. That is a 404 — **CRD is not a FHIR server**, it is a CDS
Hooks server, and it registers under the FHIR release prefix
(`CdsHooksController.URL_BASE = "/cds-services"`, mapped as `FHIR_RELEASE + URL_BASE`):

| probe | result |
|---|---|
| `GET :8090/r4/cds-services` | **200** — one service, `order-sign-crd` ✅ |
| `GET :8090/actuator/health` | 200 `{"status":"UP"}` (only with the env var below) |
| `GET :8090/cds-services` | 404 |
| `GET :8090/metadata` | 404 |
| `GET :8090/` | 200 (`HomeController::index()`) |

`/actuator/health` reports a permanent DOWN without
`MANAGEMENT_HEALTH_ELASTICSEARCH_ENABLED=false` (fix #4 confirmed): CRD inherits HAPI's
Elasticsearch health contributor but runs on H2.

`localDb.path: CDS-Library/CRD-DTR/` is **CWD-relative**, so `server:bootRun` must be invoked
from the repo root (fix #3 confirmed): all **12 topics** load — HomeBloodGlucoseMonitor,
HomeHealthServices, HomeOxygenTherapy, HospitalBedsAndAccessories, Hypoxemia,
ImmunosuppressiveDrugs, LowerLimbProsthesis, NonEmergencyAmbulanceTransportation,
PositiveAirwayPressureDevices, RespiratoryAssistDevices, UrologicalSupplies, Ventilators.
30 CQL files, **0 pre-compiled ELM** — CRD translates CQL to ELM at boot.

### VSAC is a hard requirement, not an assumption

`valueSetCachePath: ValueSetCache/` does not exist in the repo, and **67 distinct VSAC value sets**
then fail to load:

```
ERROR o.h.davinci.endpoint.vsac.ValueSetCache : ValueSet (2.16.840.1.113762.1.4.1219.188) not found in cache dir. It will NOT be available!
```

The OIDs are VSAC-internal "durable" identifiers. Public terminology servers cannot resolve them —
`https://tx.fhir.org/r4/ValueSet?url=oid:2.16.840.1.113762.1.4.1045.159` returns an **empty
bundle**, and `terminology.hl7.org` 404s. So the cache can only be filled with a **VSAC API key**.
Plan assumption 2 is therefore confirmed: an offline run needs either a key or a pre-seeded
`ValueSetCache/`. Rules still evaluate without them, but any rule gated on one of those 67 value
sets will not match.

### Two different R4 model versions were in play

| | HAPI | `hapi-fhir-base` | `org.hl7.fhir.r4` |
|---|---|---|---|
| test-ehr | 8.2.0 | — | **6.5.18** |
| CRD (as resolved) | 8.2.1 | 6.10.5 | **6.1.2.2** |

`hapi-fhir-structures-r4` is a 32 KB marker jar in HAPI 8.x; the real model classes live in
`org.hl7.fhir.r4` (12 MB), and `javap` confirms every version from 6.1.2.2 to 6.10.4 declares
`protected Type code` plus a working `getCodeCodeableConcept()`. The version skew is real but, on
its own, **not** the cause — the probe above parses correctly on CRD's *own* classpath even at
6.1.2.2. It is still worth pinning, via a non-invasive init script rather than a build edit:

```groovy
// /tmp/davinci-scratch/force-r4-model.gradle — pin the R4 core model to what test-ehr resolves
allprojects { configurations.all { resolutionStrategy.eachDependency { d ->
    if (d.requested.group == 'ca.uhn.hapi.fhir' && d.requested.name == 'org.hl7.fhir.r4') {
        d.useVersion '6.5.18'
    }
} } }
```

```bash
./gradlew server:dependencyInsight --configuration runtimeClasspath \
        --dependency org.hl7.fhir.r4 --init-script force-r4-model.gradle
#   ca.uhn.hapi.fhir:org.hl7.fhir.r4:6.1.2.2 -> 6.5.18
```

### The order-sign request contract (three ways to get it wrong)

All three of these are 400s with unhelpful messages, so the working shape is recorded in full:

1. `hook` is **required** (`rejected value [null]`).
2. `context` is **required** — the prefetch templates interpolate `{{context.patientId}}`, so
   top-level `patientId`/`draftOrders` are not accepted.
3. `context.draftOrders` must be a **FHIR `Bundle`**, not a bare resource and not a
   `{ "DeviceRequest": { "id": … } }` map. A bare DeviceRequest gets
   `class DeviceRequest cannot be cast to class Bundle`.

```json
{ "hook": "order-sign", "hookInstance": "demo-001",
  "fhirServer": "http://localhost:8080/fhir", "userId": "pra-hfairchild",
  "context": {
    "patientId": "pat013",
    "draftOrders": { "resourceType": "Bundle", "type": "collection",
      "entry": [ { "resource": { "resourceType": "DeviceRequest", "id": "devreq037" } } ] } } }
```

**CRD hydrates missing prefetch itself** (`PrefetchHydrator.hydrate()`), running each
`prefetchElements` template against `fhirServer` with `HttpMethod.GET` and writing the result into
the request. So a minimal request with no `prefetch` block is correct and sufficient — and note
that hydration **overwrites** any prefetch you do send, so a hand-built bundle is not a way to
inject data.

### Working end-to-end result

`POST /r4/cds-services/order-sign-crd` with the request above — CRD fetches the DeviceRequest and
Coverage from test-ehr, builds criteria, matches the CQL rules, and returns:

```
HTTP 200 | 13828 bytes | 2.7s
CARDS: 2 (byte-identical)
  indicator: info
  topic:    dtr-clin  (DTR Clin)
  summary:  Home Blood Glucose Monitor: Documentation Required.
  detail:   Documentation Required, please complete form via Smart App link.
  suggestions[0]:
    label: "Save Update To EHR"
    actions[0]: { type: "update",
                  description: "Update original DeviceRequest to add note",
                  resource: { insurance: [ Coverage/cov013 ],
                              note: [...],
                              extension: [ ext-coverage-information ] } }
```

The `dtr-clin` card with an `update` action is the hand-off to DTR — the coverage-requirements
half of the demo is done. Before the seed data was restored the same request returned the info
card *"Unable to (pre)fetch any supported bundles."*, and the log said why:

```
r4/FhirBundleProcessor::processDeviceRequests: 1 DeviceRequest(s) found
r4/FhirBundleProcessor::createCriteriaList: empty codes list!
r4/FhirBundleProcessor::createCriteriaList: empty payers list, working around by adding CMS!
WARN o.h.d.endpoint.cdshooks.services.crd.CdsService : RequestIncompleteException …
```

`createCriteriaList` is fed `deviceRequest.getCodeCodeableConcept()`; empty coding list → no
criteria → no rule matches → `results.isEmpty()` →
`RequestIncompleteException.NoSupportedBundlesFound()` (`OrderSignService:92-93`). The
"Unable to (pre)fetch" wording is actively misleading — prefetch succeeded, the code was missing.

Two minor CRD observations: the response contains the **same card twice** (identical `uuid`
included), and suggestion actions carry `type`/`description` with no `text` key.

---

## Cross-cutting conclusions

---

## §3 Phase 2 — reprovision into this folder, and bring the stack up

**`/tmp/davinci-scratch` was wiped** between sessions, taking the JDK tarball, the Maven tarball, all six
clones and the extracted PDF text with it. Only the three `.md` files survived, because they are
the only things on `/mnt/c`. **Everything now lives in this folder** and `/tmp` is abandoned.

### Layout

```
davinci-mock/
  bin/env.sh          single sourced env block — toolchain, ports, heap caps, swap points
  bin/clone.sh        clone one repo at an exact SHA, shallow
  bin/up.sh           start 5 services in dependency order, poll real readiness endpoints
  bin/down.sh         stop in reverse order; --purge also clears on-disk state
  runtime/jdk17       Temurin 17.0.20.1      runtime/maven   Apache Maven 3.9.9
  repos/<svc>         6 clones, all SHA-verified by bin/clone.sh
  logs/ pids/ state/  per-service log, PID file, runtime state
```

`bin/clone.sh` does `git init` + `git fetch --depth 1 origin <sha>` + `checkout FETCH_HEAD`, then
**asserts `git rev-parse HEAD` equals the requested SHA** and fails loudly otherwise. A shallow
single-commit fetch matters here: full history of six repos on a 9p mount is minutes of I/O for
nothing.

Pinned: `CDS-Library@560403a97a4c50248713fad90314faaeeff7977d` (2024-11-18, still `master`) — 12
`CRD-DTR/` topics and 4 `PriorAuth/` topics with pre-compiled ELM, matching what Phase 1 recorded.

### Environment: 9p is the dominant cost, and it is not small

`/mnt/c` is a **9p (DrvFs)** mount with with limited free space. Measured, 2000 small files:

| filesystem | write 2000 small files |
|---|---|
| `/mnt/c` (9p) | **9.85 s** (~5 ms/file) |
| `/` (ext4) | **0.04 s** (~0.02 ms/file) |

**~260× slower.** That is not noise, it changes every number in the plan:

| step | Phase 1 recorded | on 9p |
|---|---|---|
| test-ehr cold start | 25–40 s | **314 s** |
| `npm ci` crg / dtr | — | **12 min / 14 min** (1195 / 1218 packages) |
| CRD `server:bootRun` | ~90 s cold | 227 s app + ~4 min build |
| PAS `bootRun` | 3.6 s app | 65–132 s app |
| order-sign card | 2.7 s | 15.7 s |
| webpack build (either) | — | 77 s / 102 s |

Consequence: **repos and toolchain live here** (they are the irreplaceable part), but the derived
caches go to ext4 — `GRADLE_USER_HOME=/root/.cache/davinci-mock/gradle`; Maven's `~/.m2` already
resolved there on its own. Both are overridable in `bin/env.sh`. `node_modules` stays in the repos
because it has to be next to the code, and a bind-mount or symlink on DrvFs is not worth the
fragility.

### Where CDS-Library goes — `CRD/server/`, not the repo root

**Correction to §2.** The log said "localDb.path is CWD-relative, so `server:bootRun` must be
invoked from the repo root". The truth is more specific and the difference is fatal. `bootRun` has
no `workingDir` override (`server/build.gradle:38`), so the app's CWD is the **`server`
subproject** directory, regardless of where `gradlew` is invoked from. `Dockerfile:25` confirms it:

```dockerfile
COPY --from=builder /CRD/server/CDS-Library ./CDS-Library/   # line 25, after WORKDIR /app
```

Two successive hard exits taught this, each with a different missing directory:

```
FATAL ERROR: Failed to reload from folder: file path CDS-Library/CRD-DTR/ does not exist
FATAL ERROR: Failed to reload examples from folder: file path CDS-Library/Examples/ does not exist
```

The second one matters: **CRD needs the whole library, not the `CRD-DTR/` subtree.** `server/build.gradle:32`
also does `processResources { from('CDS-Library') }`. Copy all 1.8 MB of the pinned clone to
`CRD/server/CDS-Library/` and both errors go away.

**PAS is the opposite case and needs no such care**: `bootRun` there is the *root* project, so CWD
is the repo root, and `config.properties`'s `CDS_library=CDS-Library/PriorAuth/` resolves against
`prior-auth/CDS-Library/PriorAuth/`. Confirmed by `Database::write(Rules, {…HomeBloodGlucoseMonitorPriorAuthRule.elm.xml})`
in the boot log — the pre-compiled ELM is genuinely being read.

Do **not** run `./gradlew embedCdsLibrary` to solve this: it does `rm -rf CDS-Library` first
(`build.gradle:99`) and then clones unpinned `master`, discarding the pin.

### `PORT` beats `REACT_APP_SERVER_PORT` — a global env var hijacks dtr

dtr's `bin/www:21`:

```js
const port = normalizePort(process.env.PORT || serverPort);
```

`bin/env.sh` originally exported `PORT=3001` for crd-request-generator. Because plain `PORT` wins,
**dtr bound to 3001 instead of 3005**, and then crg died on `EADDRINUSE` — and because dtr answers
`/` with 200, the status table showed a *healthy* stack while crg was dead and `/public_keys` was
being served by the wrong process. Three symptoms, one cause. `PORT` is now passed per service in
`up.sh`, never exported globally.

### Item 18 has a second half: CORS

Upstream `corsOrigins` is `3000, 3002, 3005` — **it does not include 3001**. Running crg on 3001
(item 18's fix) therefore gets the browser blocked by CRD. `bin/env.sh` sets `CORS_ORIGINS` to the
upstream list plus 3001. Relaxed binding **replaces** the whole list, so the upstream entries are
repeated rather than assumed.

### dtr's webpack build needs 1280 MB, the server needs 256 MB

At the `PLAN.md` §2 cap of 256 MB, `npm run buildFrontendProd` dies:

```
FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
Aborted (core dumped)
```

The 256 MB figure is a *runtime* cap and is fine for `node ./bin/prod`. The build needs
`--max-old-space-size=1280`. `up.sh` uses `DTR_BUILD_XMX` for builds and `NODE_XMX` for serving.

### Two plan corrections

- **dtr needs no CDS-Library checkout.** `PLAN.md` §6 Phase 1 says it does. It does not:
  `src/cdex.js:158` fetches the Questionnaire **from the FHIR server at runtime** (via the Task in
  `fhirContext`), so test-ehr is the only source it needs.
- **Fix #5 is moot at this SHA.** CRD master already ships
  `launchUrl: http://localhost:3005/launch` — absolute, pointing at standalone DTR. No change needed.

Also: `debug=true` (needed for fix #7) is read by Spring Boot as well, so PAS runs at DEBUG logging
and its log is large. Harmless, but it is why `pas-run.log` fills quickly.

### State: all five up, chain re-verified end to end

```
SERVICE                  PORT   PROBE                              STATE
test-ehr                 8080   http://localhost:8080/fhir/metadata UP
crd                      8090   http://localhost:8090/r4/cds-services UP
prior-auth               9015   http://localhost:9015/fhir/metadata UP
dtr                      3005   http://localhost:3005/             UP
crd-request-generator    3001   http://localhost:3001/             UP
```

`/actuator/health` on CRD is `{"status":"UP"}` with `MANAGEMENT_HEALTH_ELASTICSEARCH_ENABLED=false`
— fix #4 confirmed again. Also 200: `dtr /launch`, `crg /public_keys`, `crg /health` (an endpoint
not previously recorded).

**CRD card** — `POST /r4/cds-services/order-sign-crd`, `pat013` + `devreq037` (E0607): HTTP 200,
`info` / `Home Blood Glucose Monitor: Documentation Required.` / suggestion `Save Update To EHR`
with an `update` action. One card this time; Phase 1 saw the same card twice.

**PAS** — `POST /fhir/Claim/$submit` with `bundle-items.json`: HTTP 201, `disposition: Pending`,
**2 items**, each with an `extension-authorizationNumber`. Then the timer:

```
07:52:45.354  [nio-9015-exec-3]  PENDING   11ff335b…/98765400001AZ
07:53:00.576  [Timer-0]            GRANTED   39c29ab9…/98765400001AZ   (+15.2s, DELAY=15000)
```

Still no clean read-back: `GET /fhir/debug/ClaimResponse` remains the only usable one (HTML table,
contains both `Granted` and `Pending`).

### `down.sh` reported "stopped" while all five ports stayed bound

The most misleading failure in the whole supervisor, and worth writing down because the output
looked like success:

```
  ok crd-request-generator stopped
  ok dtr stopped
  ok prior-auth stopped
  ok crd stopped
  ok test-ehr stopped
==> remaining listeners on stack ports:
LISTEN 0 100 0.0.0.0:9015 users:(("java",pid=14865,...))     <-- still there
LISTEN 0 100 0.0.0.0:8080 users:(("java",pid=13581,...))
LISTEN 0 100 0.0.0.0:8090 users:(("java",pid=14144,...))
LISTEN 0 511 0.0.0.0:3001 users:(("node",pid=15348,...))
LISTEN 0 511 0.0.0.0:3005 users:(("node",pid=15324,...))
```

Every PID in that list differs from the one `up.sh` recorded. Two independent causes:

1. **A recorded PID is not the process holding the port.** `mvn spring-boot:run` is a shell script
   that execs a *separate* JVM, and Gradle's `bootRun` runs inside a daemon-launched process tree.
   The recorded wrapper dies; its children do not.
2. **Killing the process group did not reach them.** With `setsid`, `$!` in `( … & echo $! )` is
   not reliably the new session leader's PID, so `kill -TERM -$pid` targeted a group that did not
   contain the listeners.

The fix is to stop treating the PID as the contract and treat **the ports** as the contract:
`down.sh` now sweeps anything still listening on the five stack ports.

The sweep needs an ownership test, because an unrelated Next.js app shares this box. Neither signal
alone is sufficient:

| signal | works for | fails for |
|---|---|---|
| `/proc/<pid>/cmdline` | the JVMs (full classpath under `$DAVINCI_ROOT`) | Node — cmdline is just `node ./bin/prod` |
| `/proc/<pid>/cwd` | both | — |

Verified in both directions: the two Node listeners were killed once cwd was added to the test, and
the Next.js app on `:3000` was left untouched. `pkill -f` is deliberately **not** used here for the
reason in the operational note below.

### Operational note, self-inflicted

`pkill -f "GradleDaemon"` killed **the shell running it** — `pkill -f` matches the full command
line, and the invoking `zsh -c` string contained the pattern. It took PAS down with it as collateral
and silently aborted the rest of that command. Use a pattern that cannot match the invoking command,
or kill by PID. `bin/up.sh` now records PIDs, so this should not recur.


---

## §4 Phase 2b — Keycloak reinstated, VSAC seeded, and the browser chain driven to PAS

**2026-09-27. All BOOT evidence. Supersedes the Keycloak retirement in §0 and the "dtr, crg and
test-ehr remain unexecuted" note above.**

The previous session left the stack at "the questionnaire renders". The log's last line was
`POST /fhir/R4/questionnaireresponse` → stored, and `logs/prior-auth.log` showed **no** `$submit`
after the `demo.sh` run. So the browser path had never produced a claim. This section closes that.

### 8. The missing leg is a button, and dtr owns the submit

`QuestionnaireForm.outputResponse("completed")` is wired to **`PROCEED TO PRIOR AUTH`**
(`QuestionnaireForm.jsx`, `getDisplayButtons`). It builds the Claim itself and hands it to
`setPriorAuthClaim`, which makes `App.jsx:813` swap the entire form for `<PriorAuth claimBundle=… />`.
That panel's own **`Submit`** button is the only thing in the whole stack that POSTs
`Claim/$submit` from the browser (`PriorAuth.jsx:556`).

Nothing in crg or test-ehr submits to PAS. Anyone grepping those two repos for `9015` finds nothing
and concludes the browser cannot reach PAS. It can — through dtr.

### 9. Keycloak: retired for a day, and the reasoning was wrong

Retirement on 2026-09-26 rested on `use_oauth: false`, `checkJwt: false` and PAS's H2 `/auth`. All
three are true and all three are irrelevant, because **not one API-level test needs a token**. The
order-sign hook never expands a value set, so `demo.sh` passed 12/12 with `:8180` refusing
connections. The moment a real browser clicked through, `dtr`'s `launch.js` called
`fhirclient oauth2.authorize`, which fetched `{iss}/.well-known/smart-configuration`, which
test-ehr's proxy forwards to a Keycloak that was not there.

The generalisable error: **absence of a failure in the tests you ran is not evidence of absence in
the paths you did not run.** The stack was green and structurally incomplete at the same time.

### 10. The realm needs 26 SMART client scopes or nothing works

`fixtures/keycloak/BurdenReduction-realm.json` defines realm `BurdenReduction`, public client
`app-login` (PKCE `S256`), user `dtr`/`dtr-demo`, and **26 SMART client scopes**. Without the scopes
Keycloak rejects the `authorize` request outright, because the scope list the UI sends
(`launch user/Observation.read patient/Coverage.read …`) is not standard OIDC. This is not
discoverable from the code — it is only visible as a rejected authorize request.

`security.auth_redirect_host` must be left **empty**. `AuthProxy.java:170` uses it as the complete
`scheme://host:port`; set to a bare hostname it produces `192.0.2.10/test-ehr/_auth/…` and
Keycloak rejects the redirect. Empty means "derive it from the request", which is also DHCP-proof.

Keycloak 26.7.4 lives at `/opt/keycloak` on **ext4**, not in this folder: C: was at 99 % and /mnt/c
is slow 9p. It needs **JDK 21**, so `up.sh` overrides `JAVA_HOME` for that one service, because
`env.sh` otherwise pins the project's JDK 17 and `kc.sh` runs `$JAVA_HOME/bin/java`. `down.sh`'s
ownership test needed a **second root** for the same reason — Keycloak is not under the project path,
so the port sweep called `:8180` "not ours" and left it bound.

### 11. VSAC: the questionnaire throws on the first value set it cannot resolve

`$questionnaire-package` dies on the first unresolvable value set
(`QuestionnairePackageOperation.java:333`), and "cannot resolve" means "ask VSAC", and VSAC wants an
API key. `bin/seed-valuesets.sh` pre-seeds the value sets from public `tx.fhir.org` instead — no
signup. Two traps, both silent:

- **Never cache an unexpanded value set.** `…/r4/ValueSet?url=…` returns
  `expansion.contains == 0`. Caching that *silences the error* and yields a questionnaire with
  **zero answer options** — a mock that looks right and is quietly wrong. The seeder uses `$expand`
  and refuses to write a file unless `contains > 0`.
- **`VSAC_CACHE_DIR` must keep its trailing slash.** `CdsConnectFileStore.java:315` and
  `LocalFileStore.java:171` both build the path as `getValueSetCachePath() + filename` with no
  separator. Upstream's `ValueSetCache/` ends in a slash by luck, so a tidy override without one
  yields `…/vsac-cacheValueSet-R4-<oid>.json`, every lookup misses, and the boot log cheerfully
  reports all 65 as added. `env.sh` forces the slash; `up.sh` asserts the concatenated path.

### 12. What the browser run proved, and three ways to get it wrong

`bin/e2e-browser.py` — 14 assertions, ~3 min, **PASS 14/0 on two consecutive runs**.

```
crg :3001  pat013 + E0607 -> card "Documentation Required"
  -> dtr :3005 -> Keycloak :8180 (dtr/dtr-demo) -> questionnaire
  -> 17 required answers -> PROCEED TO PRIOR AUTH -> dtr builds the Claim -> Submit
  -> POST :9015/fhir/Claim/$submit  201  disposition=Pending outcome=queued
  -> $inquire x3                    disposition=Granted
```

Cross-checked in `logs/prior-auth.log` — the usual 15 s `DELAY` timer:

```
16:40:39.835  POST /Claim/$submit fhir+JSON
16:40:39.918  generateAndStoreClaimResponse(c37fe4f8…/0M987654001AZ, disposition: PENDING)
16:40:54.960  generateAndStoreClaimResponse(46204484…/0M987654001AZ, disposition: GRANTED)
```

**PAS needs no CORS config.** It has no `addCorsMappings`, and answers `ACAO: *` including preflight
— checked with a real `Origin` header because dtr's submit is cross-origin and the source looked
like a blocker. There isn't one. A prediction from reading code, killed by one `curl`.

**`PriorAuth.jsx:34` picks the wrong PAS on any non-localhost origin:**
`hostname === "localhost" ? "http://localhost:9015/fhir" : "https://prior-auth.davinci.hl7.org/fhir"`.
From the LAN origin (`:3005` on `192.0.2.10`) the panel offers the **public** payer. The endpoint
field is editable, so the test overwrites it. A demo should not depend on someone noticing.

**Date pickers must be targeted through their wrapper.** LForms gives text inputs
`id="<linkId>/1/1"`, but dates are ng-zorro `<nz-date-picker>` with the id on the **wrapper** and
only a generated `ng-tns-*` class on the input. Filling them by document index looks fine and is
wrong: the widget re-renders as each date commits, so `nth(1..3)` were stale and **three of five
dates silently never landed**. Use `nz-date-picker[id^="<linkId>"] input` + `Enter`.

**Verify the form from the QuestionnaireResponse, not from `input_value()`.** The choice widgets are
AjaxAutocomplete, and the multi-selects replace the input with a selected list, so a recorded answer
never appears in the input. `window.LForms.Util.getFormFHIRData('QuestionnaireResponse','R4',
'#formContainer')` is the only honest check — and it is what caught the three missing dates, which
the widget-level assertions had called fine.

### 13. Selecting the patient: two wrong answers before a right one

The crg tile is a row — `[Patient Info (onClick) | Divider | Request Selection]`. The
"Click to select this patient" caption is **inside** the Patient Info box; the request dropdown is in
a **sibling**. So the row is the only common ancestor and clicking its centre hits the Divider.

- A Playwright `div.filter(has=…).filter(has=…)` chain matched a **different patient** and selected
  pat015. The assertion `pat013 in body` passed anyway, because the modal itself lists pat013.
- A JS "innermost ancestor containing the id" climb walked past the tile into the **whole grid**,
  whose text also contains `pat013`, so the centre-click landed mid-grid — on pat015 again.

The assertion was wrong in the same way as the selector: *substring present* is not *the right
element did the thing*. What works: tag the DOM in JS. Climb from the `pat013` text node to the row
(identified as the ancestor holding exactly one request dropdown **and** the caption), then tag the
`Patient Information` ancestor separately and click that.

### 14. Still open

- CRD cannot resolve the CQL expression references `ALTERNATIVE_THERAPY`,
  `RESULT_QuestionnaireAdditionalUri`, `RESULT_QuestionnairePARequestUri` in
  `HomeBloodGlucoseMonitorRule`, so the form arrives un-prefilled and dtr shows "Problems occurred
  while prefilling this request". Pre-existing, upstream-looking, unrelated to Keycloak.
- One value set still 404s in the browser: `…2.16.840.1.113762.1.4.1219.84`. Does not stop the flow.
- `PLAN.md` still describes a 5-service stack with no Keycloak. Stale as of this section.
  **Closed 2026-09-27:** `PLAN.md` §0b, the acceptance criteria and the scope heading are all
  corrected, and `TEST-FLOW.md` §7's "NOT INSTALLED — deliberately" decision is marked as the
  mistake it was. The two remaining "5 services" mentions in `PLAN.md` (inside the Phase 2 code
  block and the §3 layout listing) are left as period-correct history.

### 15. The e2e's missing leg was a poisoned flag inside CRD (closed, 2026-09-30)

Section 3 has failed every run since the IRIS swap in the same way: the "Complete …
in DTR" button never appears, the click times out, and the run dies before any popup
exists. `demo.sh` stayed 12/12 the whole time. Three symptoms that only made sense
together once the mechanism was found:

- **Every card flow minted exactly six `POST /fhir/r4/_services/smart/Launch`** with
  `appContext` carrying the three questionnaires (`Order`/`FaceToFace`/`Lab` × 2 cards),
  followed by zero SMART traffic. Red herring: crg's `DisplayBox.modifySmartLaunchUrls`
  fires one launch-context POST per `type=smart` card link **at render time** and
  discards the result (`linkCopy` is reassigned after the promise resolves). 2 cards ×
  3 links = 6; nothing is ever opened.
- **The live CRD responses had `systemActions: 0`** even though every card's
  `Save Update To EHR` suggestion action carried `ext-coverage-information` with
  `doc-needed=admin` and `questionnaire=…/HomeBloodGlucoseMonitorOrder`.
- **Zero `Extension object class` log lines in the entire boot** — the scan in
  `hasDocNeededExtension` never ran.

Mechanism: CRD's `hasDocNeededExtension(List<Card>)` (CdsService.java:343) caches its
result **write-once on the singleton** via `docNeededChecked`/`docNeededPresent`. The
first cds-services POST after boot that reaches the scan decides the value **for the
whole boot**. The poison was the prefetch-less reprovision request
(`fixtures/order-sign-prefetch.json`, no `prefetch` and no `fhirAuthorization`) — on a
cold boot it throws `RequestIncompleteException` ("Unable to (pre)fetch any supported
bundles"), degrades to the summary card, the scan sees a card with no suggestions,
caches `false`, and every later response silently drops `systemActions`. With
`systemActions` empty, `extractQuestionnairesFromCoverageInfo` returns `[]` and crg
never renders the launch section. The certified runs passed because the accident of
ordering warmed the flag `true` first; `up.sh --reset` + demo-before-e2e flipped it.

Fix (no upstream patch, no build): warm the flag with a real prefetch-carrying request
first. `fixtures/order-sign-warmup.json` is the crg-shaped request (prefetch keys
`user`/`deviceRequestBundle`/`coverageBundle`); `up.sh` post-flight POSTs it right
after CRD is up and fails loud if `systemActions` comes back empty (the recovery is a
CRD restart so the warmup runs first). The flag is write-once, so afterwards demo.sh
and the e2e are safe in any order.

Verified: cold CRD → warmup first → `systemActions: 1` (questionnaire
`…/HomeBloodGlucoseMonitorOrder`) → `e2e-browser.py` **14/14** twice consecutively
(2026-09-30); `demo.sh` 12/12 unchanged.
