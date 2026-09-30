# IRIS-LXC-PLAN.md — checkpoint 2026-09-30 (late)

## Status
**The EHR swap is implemented; Phase 6 gate PASSED 2026-09-30.** Phase 4 (FHIR R4
serving) is DONE and the OAuth wall is RESOLVED; the port-8080 SMART shim is
built and its full surface verified standalone; the DaVinci seed imports into
IRIS and every query the browser flow issues answers 200. The 6-service stack is
back up with `bin/ehr-shim` on 8080; `demo.sh` 12/12 and `e2e-browser.py` 14/14
(two consecutive runs) against the IRIS-backed stack.

What changed since the section below was written:
- **The final e2e blocker was a CRD bug, not IRIS.** CRD's `hasDocNeededExtension`
  caches its result write-once on the CdsService singleton; the prefetch-less
  reprovision fixture (demo step 1) degrades to the summary card on a cold boot,
  caching `false`, so every later response silently dropped `systemActions` and crg
  never rendered the "Complete … in DTR" button — the browser leg failed at the
  SMART launch while all API drivers stayed green. Fixed by warming the flag with
  `fixtures/order-sign-warmup.json` (a real prefetch-carrying request) first thing
  in `up.sh` post-flight, which also fails loud if the flag was already poisoned.
  See AGENTS.md "Known, accepted limitations".
- **Go/no-go PASSED (200)**: a `client_credentials` token (`aud=` the FHIR base
  URL) makes `/fhir/r4/Patient?_summary=count` return 200. The missing link was
  `OAuthClientName` empty on the `/fhir/r4` RESTCSPConfig row, fixed in **HSSYS**
  (data lives there, not %SYS/HSLIB).
- **`bin/ehr-shim/server.js`** now owns port 8080: FHIR pass-through to IRIS with
  an auto-minted bearer token (300 s TTL), `POST /fhir/r4/_services/smart/Launch`,
  `.well-known/smart-configuration`, `/auth`→Keycloak, `/test-ehr/_auth/{launch}`
  (the path root is deliberate — the Keycloak realm only allows
  `http://localhost:8080/test-ehr/*`), and `/token` with launch-context injection.
  Zero Keycloak realm changes.
- **`bin/seed-iris.sh`** PUTs the test-ehr seed-data into IRIS by body id (IRIS
  rejects a body id that does not match the URL id; POST would ignore the id and
  assign internal numeric ids the browser cannot address) and asserts the 9
  crg/dtr queries. `PractitionerRole` has a trailing-space key upstream
  (`"organization "`) that IRIS's parser rejects — normalized in the seed script.
- **`bin/env.sh`** lines 143/153 now `/fhir/r4` (the two values that must change
  together), `IRIS_*` fixture vars documented; `bin/up.sh` launches `ehr-shim`;
  `bin/demo.sh` EHR base swapped; `bin/down.sh` sweeps `ehr-shim` by PID file.

### What is running
| Service | Where | State |
|---|---|---|
| IRIS superserver | container `10.0.3.108:1972` | up |
| IRIS web (Apache+CSP) | `10.0.3.108:52773` | up |
| IRIS FHIR R4 (TLS) | `https://10.0.3.108:52774/fhir/r4` | up — the EHR |
| IRIS internal OAuth 2.0 | `https://10.0.3.108:52774/oauth2/.well-known/openid-configuration` | discovery OK |
| ehr-shim | host `:8080/fhir/r4` | verified standalone; in stack |
| 6-service stack | 8180/8090/9015/3005/3001/8080 | Phase 6 PASSED — demo 12/12, e2e 14/14 ×2 |

### FHIR gate — RESOLVED 2026-09-30. The three things that were blocking it
All three were missed because the failure surfaces as a *different* error each
time, and each one needs a separate bootstrap step that the kit does not run in
Community:

1. **`HS.Util.Installer.ConfigItem` was empty.** `InstallNamespace` throws
   `namespace not defined in ConfigItem table` whenever
   `##class(HS.Util.Installer.ConfigItem).%ExistsId(namespace)` is false. That
   table is the *instance-configuration* registry (`^%SYS("HealthShare","Instances",<Name>)`),
   and the step that populates it never ran. Not a namespace-type check — an
   **empty table**. Fixed by inserting the row directly:
   `Name="HSSYS"`, `Type="Foundation"`, `CreatedAt=##class(%Library.UTC).NowLocal()`,
   via `%New()`/`%Save()` (returns 1).
   - `Type` must be `Foundation`. `HS.Util.Installer.Foundation` is the *only*
     subclass of `ConfigItem` in Community (`HS.Util.Installer.IRIS` and
     `.HealthShare` are license-gated and do not exist), and `TypeIsValid`
     compares against `GetConfigTypeName(0)` of a compiled subclass.
   - `GetSubclasses()` on `ConfigItem` returns `""` even though `Foundation` is a
     real subclass. Use `%IsA` to test that, not `GetSubclasses`.
2. **`%SYSTEM.Context.HealthShare.Manager` did not exist.** `InstallInstance`
   failed with `<CLASS DOES NOT EXIST> %SYSTEM.Context.HealthShare.Manager`
   because `Do ##class(%ZHSLIB.Context.Manager).BootstrapMappings()` is guarded by
   `If ..IsHealthShareInstance()` and therefore never runs on IRIS for Health.
   Calling `BootstrapMappings()` manually creates the class.
3. **Neither method can be reached from the console's own helpers.**
   `HS.FHIRServer.ConsoleSetup.CreateEndpoint` prompts for a FHIR version from a
   list that is empty in this install and rejects every answer with
   "Enter a number from 1 to 0". The FHIR Management REST API is the only
   non-interactive route that works: `POST /csp/fhir-management/api/login` with
   `{"user":"_SYSTEM","password":"..."}` returns an access token whose lifetime is
   **60 seconds** (`exp - iat`), so a cached token is stale almost immediately —
   log in on *every* call. Helper written to `/root/fa`.

   What finally worked, all from `zn "HSSYS"`:
   ```
   Do ##class(HS.FHIRServer.Installer).InstallNamespace("HSSYS")
   Do ##class(HS.FHIRServer.Installer).InstallInstance("/fhir/r4",
        "HS.FHIRServer.Storage.JsonAdvSQL.InteractionsStrategy",
        "hl7.fhir.r4.core@4.0.1","","FHIR R4 endpoint",1,"","","fhir-r4")
   ```
   `InstallNamespace` loads and saves `hl7.fhir.r3.core@3.0.2`,
   `hl7.fhir.r4.core@4.0.1`, `hl7.fhir.r5.core@5.0.0`, `hl7.fhir.us.core@3.1.0`
   and schedules the "FHIR Purge Expired Search Results" task.
   `InstallInstance` generates and compiles the `HSFHIR.X0002.*` class set and
   builds the tables. Both are **void** methods — never `Set sc=` their return;
   the console reports a bogus `*Function must return a value at InstallNamespace+40`.

- **Why HSSYS and `/fhir/r4`.** HSSYS is where the FHIR Management REST app
  lives, where `HS.FHIRServer.*`/`^HS.FHIRServer.Repo` globals live, and from
  where `HS_Util_Installer.ConfigItem` is visible; the purge task is scheduled
  with `HSSYS`. `/fhir/r4` is what the Management UI's own endpoint template
  contains (name `fhir-r4`, url `/fhir/r4`, namespace `HSSYS`; saved as
  `/root/endpoint-r4.json`).
- **Accepted, non-blocking:** FHIR profile validation is not installed — the
  installer logged "FHIR profile validation not enabled" because `JAVA_HOME` was
  not set at install time.

### The OAuth wall — IRIS Community FHIR has no anonymous access
This is the finding that decides the rest of the project. **Every data
interaction with an IRIS for Health FHIR endpoint requires an OAuth 2.0 bearer
token. There is no configuration flag that turns this off.** Established by
reading the shipped `HS.FHIRServer.RestHandler` source, not by guessing:

- `HS.FHIRServer.RestHandler.IsRequestAuthenticated()` is literally
  `return $USERNAME '= "UnknownUser"`.
- `Page()` contains the block, with its own comment:
  > `// The only unauthenticated interaction allowed is metadata.`
  ```objectscript
  if ( ('..#isInteropAdapter) {
      if ( ('..IsRequestAuthenticated()) && (accessToken = "") && ($Piece(pRequestPath,"/",*) '= "metadata") ) {
          Set %response.Status = $$$HTTP401
  ```
  So: authenticated-without-a-token → 401. Unauthenticated (`$USERNAME` =
  `UnknownUser`) → the *other* branch, `UpdateUserInfoFromToken`, also 401s,
  because with no OAuth client configured there is no token handler to supply a
  username. Both directions 401. `/fhir/r4/metadata` is the sole exemption, and
  that is exactly what is observed.
- The Management UI's `_allow_unauthenticated` checkbox is **a no-op**. It is
  derived client-side as `!!(Math.floor(service_config_data.debug_mode/4)%2)` —
  a UI convenience packed into `debug_mode` bits. Only two bits are defined
  server-side (`#define FHIRDebugNewInstance 2`, `#define
  FHIRDebugIncludeTracebacks 1`); bit 4 is referenced nowhere in the server.
  Toggling that checkbox changes no server behaviour.
- `HS.Util.RESTCSPConfig.AllowUnauthenticatedAccess` (settable to 1, and it does
  persist) is **read by nothing** in 2026.2 — a dead property.
- `HS.FHIRServer.RestHandler.#isInteropAdapter = 1` skips both 401 branches, but
  it also skips `fhirService = ##class(HS.FHIRServer.Service).EnsureInstance(appKey)`
  in the same method, so the inherited `Page()` then has no service to dispatch
  to. It only works on `HS.FHIRServer.HC.FHIRInteropAdapter`, a subclass that
  overrides `Page()`. Not a usable shortcut for a normal R4 endpoint.
- Measured `AutheEnabled` sweep on the `/fhir/r4` CSP app (the installer sets
  `2^6+2^5+2^13 = 8288`; bit 6 = `AutheUnauthenticated`, bit 7 undocumented,
  bit 13 = `LoginToken`):

  | `AutheEnabled` | `/fhir/r4/metadata` | `/fhir/r4/Patient?_summary=count` |
  |---|---|---|
  | 8288 (installer default) | 200 | 401 |
  | 96 (`64+32`, minimal working) | 200 | 401 |
  | 32 (`AutheUnauthenticated` only) | 404 | 404 |
  | 0 | 404 | 404 |
  | 8224 (`32+8192`) | 404 | 404 |
  | 4128 (`32+4096`) | saved as 32 | 404 |

  The 401 is the FHIR handler, not CSP: the response carries the FHIR handler's
  `CACHE-CONTROL: no-cache` / `PRAGMA: no-cache` / `Expires: 1998` triple, not a
  CSP login page. The app is left at the installer default 8288.

**The supported path is OAuth 2.0, and it is bigger than it looks:**
- `HS.FHIRServer.RestHandler.PrelimTokenCheck` rejects any bearer token on a
  non-secure request — `If '%request.Secure { Quit }`. So the FHIR endpoint must
  be reachable over **TLS**, not just have a token.
- `HS.HC.OAuth2.Client.Installer.ConfigureInternalOAuthClients()` is the
  one-shot setup, and it hard-requires
  `^|"HSSYS"|%SYS("HealthShare","SSLAccess","Active")` before it will run
  (`SecureCommunicationNotActive`). It then registers, against
  `https://<host>:<port><prefix>/oauth2`:
  - a client-side `OAuth2.ServerDefinition` (via `OAuthServerDiscoverAndSave`,
    i.e. it **discovers over HTTPS**, so the discovery document must already
    be serving),
  - a *resource* client (`ClientType="resource"`, grant `authorization_code`)
    — this is the one the endpoint's `csp_config.oauth_client_name` refers to,
  - a *confidential* client named `<issuer>-sample-confidential` with grants
    `authorization_code` **and `client_credentials`**, `DefaultScope="user/*.rs"`,
    `token_endpoint_auth_method=client_secret_post`. **This is the one a headless
    shim can use** — client_credentials needs no browser and no login page.
- The two OAuth management APIs are unauthenticated at the CSP layer
  (`AutheEnabled=32`) but 401 at the handler layer, so client registration
  cannot be done with plain `curl` either.
- `HS.OAuth2.*` does not exist in Community, so this is all IRIS-core OAuth
  (`%OAuth2.Client`, `OAuth2.ServerDefinition`, `OAuth2.Client`) driven through
  the IRIS-for-Health `HS.HC.OAuth2.*` installer.
- `iris.cpf` has no `[SSL]` section at all, so IRIS is HTTP-only today. Web is
  Apache + the CSP bridge on 52773, so TLS has to be added at one of those two
  layers, and `%request.Secure` has to end up true for the FHIR app.

### Automation notes for the IRIS container
- Console access requires `_SYSTEM` / the install password; **root is refused**
  ("Access Denied" on `iris session`). The password really is validated (a wrong
  password is refused too).
- The IRIS console is line-oriented and rejects multi-line `Do ... While` blocks
  (`<SYNTAX>`, body runs at most once) and file I/O outright. Compiling a helper
  class via `$SYSTEM.OBJ.ImportDir` on a `.cls` **fails** (reported as `udl`, no
  `.int` emitted, then `<CLASS DOES NOT EXIST>`). Working channel is
  `/root/irisq`, which emits N independent `%Next()`/`Write` lines and tags each
  with an `ok` flag — the flag matters because a naive dump repeats the last row
  forever and looks like real data.
- `%Dictionary.ParameterDefinition` has **zero** rows for the FHIR installer
  classes, so method signatures must be discovered by trial, not by introspection.

> **The original checkpoint below was stale when work resumed.** It recorded
> `/var/lib/lxc/` as empty, `lxcpath` as `/mnt/e/lxc` and `lxcbr0` as DOWN. None
> of that was true: the `iris-fhir` container already existed and was running, and
> the host plumbing had already been fixed. Phase 1 was therefore *already 3/4
> done* and Phase 2 *already complete*. Do not re-run them — `lxc-create -n
> iris-fhir` would collide with the live container.

## Objective
Stand up InterSystems IRIS for Health Community **2026.2.0.221.0** from the legacy kit in a classic-LXC container **`iris-fhir`** on ext4 `/`, then wire it into davinci-mock as the real FHIR R4 EHR replacing mock `test-ehr` (8080). Honors "no container runtime": classic LXC is a system container; `irisinstall_silent` is a native install.

## Checkpoint state (re-verified 2026-09-29, this session)
- **`iris-fhir` EXISTS and RUNS** — PID changes per start, IP `10.0.3.108`, veth
  `00:16:3e:50:c1:d5` on `lxcbr0`, rootfs 793 M, Ubuntu **24.04.5** (matches the
  host and the kit's `lnxubuntu2404x64` suffix). Created from the **`lxc-ubuntu`**
  template, i.e. the documented Phase 2 *fallback*, not `lxc-create -t download`.
- `lxc.apparmor.profile = generated` + `allow_nesting = 1` — **not** the
  `unconfined` this plan originally specified. Left as-is; it has not caused trouble.
- Host plumbing already correct: `/etc/lxc/lxc.conf` has
  `lxc.lxcpath = /var/lib/lxc`; `lxc-net.service` is enabled/active with dnsmasq
  serving `10.0.3.2–254` off `lxcbr0` at `10.0.3.1/24`.
- **Kit is on ext4 at `/opt/iris-kit/`** and hardlinked into the container rootfs at
  `/var/lib/lxc/iris-fhir/rootfs/opt/iris-kit/` (link count 2, **0 extra bytes**).
  The `C:` copy still exists — not deleted, see Open.
  - `sha256 0be9c260bd0918b37764074e979518d526f760b660544ddc2b354252df9185ff`
    recorded in `/opt/iris-kit/IRIS-KIT.sha256`, **verified from inside the container**.
  - `gzip -t` passes ⇒ every CRC in the stream is intact, not just the size.
  - Confirmed **legacy kit, not Docker**: `.product` = `IRISHealth`, `kitlist` has
    the `dist/{csp,dev,devuser,docs,fop,httpd,install}` tree, and `irisinstall_silent`
    is a `#!/bin/sh` script.
- Host: 7.6 G RAM, **5.4 G available**, 2 G swap, `/` 800 G free. Ports 52773 and
  1972 free. cgroup v2, userns available. The 6-service davinci-mock stack is
  currently **down** (no listener on 8180/8090/9015/3005/3001) — fine, Phase 6.
- Stack wiring confirmed at `bin/env.sh:143,153` as this plan claimed. Note the two
  values Phase 6 must change together: `REACT_APP_EHR_SERVER` and
  `REACT_APP_INITIAL_CLIENT`, and that the path changes `/test-ehr/r4` → `/fhir/r4`.

## LXC 5.0.3 quirk: `lxc.mount.entry` is silently dropped

A bind mount of the kit via `lxc.mount.entry` **did not appear in the container**,
and neither did a deliberately invalid entry:

```
lxc.mount.entry = /nonexistent/should/fail /opt/probe-fail none bind 0 0
```

An unresolvable source must abort the start. It did not — `start_exit=0`, container
RUNNING. Meanwhile every entry from `ubuntu.common.conf` and `common.conf`
(`/sys/kernel/debug`, `/sys/kernel/security`, `/sys/fs/pstore`, `/dev/mqueue`,
`/sys/fs/fuse/connections`) **was** applied and visible in the container's
`/proc/<pid>/mountinfo`. So mount config is being dropped, not obeyed. `-l` also
produced no log file and `--log-level` is not a valid flag on this build, so the
cause was never isolated — only the behaviour is established.

**Workaround used instead: a hardlink.** Host kit and container rootfs are the same
ext4 device (`stat -c %d` = 2096 on both), so `ln` gives the container the full
1.15 GB for zero bytes and zero dependence on mount support. Verified after a
restart. This is the reason the kit does not need a bind mount, and it is strictly
better here.

## Phases
1. ~~**Host plumbing**~~ — **DONE (mostly pre-existing; verified).** `lxcpath` and
   `lxc-net` were already correct. Kit moved off `C:` to `/opt/iris-kit/`,
   `sha256sum` recorded, hardlinked into the container rootfs.
2. ~~**Create `iris-fhir`**~~ — **DONE.** Exists, running, Ubuntu 24.04.5, on
   `lxcbr0` at `10.0.3.108`. Built from the `lxc-ubuntu` template (the fallback path).
3. ~~**Install IRIS (legacy kit) in container**~~ — **DONE.** `INSTALL_EXIT=0`; instance
   `FHIR`, `/opt/iris`, `2026.2.0.221.0com`, state ok, superserver 1972, web 52773.
   `apt-get install apache2 apache2-dev` was a **prerequisite**, not a nicety (below).
4. ~~**Enable FHIR R4**~~ — **DONE.** See "FHIR gate — RESOLVED" below: `ConfigItem`
   row + `BootstrapMappings()` + `HS.FHIRServer.Installer` driven from the FHIR
   Management REST API. `/fhir/r4` serves the real CapabilityStatement.
   OAuth wall **RESOLVED** too: TLS vhost on 52774, `ConfigureInternalOAuthClients()`,
   `OAuthClientName` set on the RESTCSPConfig row (in HSSYS), `client_credentials`
   token with `aud=https://10.0.3.108:52774/fhir/r4` gets 200 on data.
5. ~~**Seed + SMART**~~ — **DONE.** `bin/seed-iris.sh` puts the test-ehr seed data
   into IRIS (pat013/cov013/devreq037 E0607 + practitioners/org/role) and asserts
   every crg/dtr query. `bin/ehr-shim/server.js` replicates test-ehr's SMART/OAuth
   surface on 8080 in front of IRIS.
6. **Stack flip** — **IN PROGRESS (final gate).** env.sh ⇒ `/fhir/r4` (done);
   up.sh launches ehr-shim (done); down.sh sweeps it (done). Accept:
   `demo.sh` 12/12 + `e2e-browser.py` 14/14 against the IRIS-backed stack.
7. **Codify** (after 6 is green): provision.sh --check (+ container presence,
   `:52774` metadata + token mint); capture the container's OAuth fixture values
   as code; update PLAN/TEST-FLOW/AGENTS credential table.

## Effort / resources
~1.5 days; heap on Phase 4. ~8–10 G on `/`. RAM 5.4 G available, ⇒2 G for IRIS.

## Risks
0. **The swap is not a config change — it is a build.** DaVinci's `crg` POSTs to
   `{ehrBase}/_services/smart/Launch` (`repos/crd-request-generator/src/containers/
   RequestBuilder.js:344`) and opens `?launch=…&iss=…` against that same base. Its
   own comment at line 341 says the endpoint "may change when the launch context
   creation endpoint becomes a standard endpoint for all EHR providers" — i.e.
   upstream concedes it is **not** standard. That endpoint and the `/auth`→Keycloak
   proxy live only in `test-ehr` (`SmartInterceptor.java`, `AuthProxy.java`); IRIS
   implements neither. So making IRIS the single `iss` requires a **shim** in front
   of it (proxy FHIR, serve `_services/smart/Launch`, proxy `/auth` to Keycloak).
   `bin/demo.sh` asserts a `launch_id` at ~lines 92-98, so a straight swap breaks
   both drivers. **Needs a decision — see Open.**
1. Phase 4 FHIR-enable steps — **RESOLVED**, see "FHIR gate — RESOLVED" above.
   The web apps were pre-created; the endpoint needed a `ConfigItem` row, a
   `BootstrapMappings()` call, and `HS.FHIRServer.Installer` driven from the
   FHIR Management REST API rather than from the console.
2. `images.linuxcontainers.org` reachability decides Phase 2 create method — **now moot, `iris-fhir` already exists.**
3. IRIS-in-LXC kernel-shm warnings — record, don't ignore.
4. LXC drops mount config (above), so anything Phase 3–6 needs from outside the
   container must be hardlinked or copied in, not bind-mounted.

## Open
- **DECISION (a) — RESOLVED, implemented.** "Full swap, done properly": IRIS FHIR
  over TLS, IRIS internal OAuth 2.0 with `ConfigureInternalOAuthClients()`, and
  the port-8080 OAuth-aware shim holding the confidential client. The browser
  (crg/dtr) sees plain 200s from `http://localhost:8080/fhir/r4` and never enters
  an OAuth flow against IRIS; the SMART launch dance still happens against
  Keycloak (unchanged realm), exactly as with test-ehr.
  - Seed data import means **PUT, not POST** (IRIS rejects POST-supplied ids and
    stores internal numeric ids the browser cannot address; PUT with a matching
    body id stores the requested id).
- The 6-service stack is back up and being re-verified against the IRIS-backed
  EHR. `demo.sh` 12/12 and `e2e-browser.py` 14/14 were certified on 2026-09-27
  against the `test-ehr` stack (tag `run-2026-09-27`, pushed — **that tag is the
  certified record and must not move**; the IRIS swap is a new, un-pushed state).
- The `C:` copy of the tarball (1.15 G) was **copied, not moved**, then hardlinked
  into the container. Deleting the `C:` original was left to the user deliberately:
  it is the only off-box copy of a proprietary kit and `/mnt/c` is not short on space.
  `rm` it whenever convenient.
- IRIS took **2677 MB** shared memory (1944 MB global buffers, auto-selected at 25%
  of RAM). Host has ~5.4 G free and the 6-service stack needs ~2.4 G heap.
  Re-check after the stack is up; cap `iris.cpf` global buffers only if the stack
  actually OOMs — a buffer cap needs an IRIS restart, which would drop the FHIR
  endpoint mid-verification.
- Non-root cold boot of davinci-mock is still unverified (carried over from
  `SESSION-NOTES.md`); not touched by this work.

## Out of scope
Docker-in-LXC, old sandbox recreation, touching the six-service stack until Phase 6.

## Phase 7 — distributable LXC image (DONE 2026-09-30, later)

The LXC machine is now a drop-in artifact: `bin/lxc-image-build.sh` (build,
maintainer-side) and `bin/lxc-import.sh github` (one-command end-user import
from the GitHub release) + `LXC-DROPIN.md` (fresh-Ubuntu runbook).

- **Determinism fix:** the container's 10.0.3.108 was a **DHCP lease**, which a
  fresh host would not reproduce. Pinned it statically: netplan
  `10-lxc.yaml` → `10.0.3.108/24` via `10.0.3.1`, resolv.conf → `10.0.3.1`
  (was a WSL-ism `10.255.255.254`). env.sh/ehr-shim/seed-iris defaults
  (`https://10.0.3.108:52774`) now hold on any default-lxcbr0 host.
- **Trims before packaging (while stopped):** `/opt/iris-kit` (1.1 G), apt
  caches/lists (473 M), logs, `/tmp` — **but NOT the WIJ, journals or ssh host
  keys**: deleting the WIJ makes IRIS think the last shutdown was abnormal and
  dumps the box into single-user journal recovery on next boot (hit on
  2026-09-30, recovered via STURECOV, then excluded from the recipe).
  Raw 8.6 G → **~7 G** → **~2.8 G** pigz-9 (2 × 1800 M parts + sha256sets).
- **Distribution:** release assets on `Abaabeel/iris-fhir` (repo flipped public
  so anonymous end users can pull); `lxc-import.sh github` fetches, verifies
  `parts.sha256`, extracts to `/var/lib/lxc`, starts, and waits for a 200 on
  `https://10.0.3.108:52774/fhir/r4/metadata`.
- **Autostart baked in:** IRIS had no start-at-boot mechanism (no unit, no
  rc.local — the original box was hand-started). Image ships
  `/etc/systemd/system/iris.service` (oneshot, RemainAfterExit, KillMode=process
  so systemd can never cgroup-kill the irisdb daemons at stop timeout). The
  ExecStop runs `iris stop FHIR` inside a pty (`script`) feeding `N`, `Y`, and a
  delayed `h` (halt) — `iris stop`'s confirm prompts read `/dev/tty`, so a plain
  ExecStop EOF-fails under systemd; and the console session lingers at its
  prompt after shutdown, so it needs the `h` to exit. End users just
  `lxc-start` the container; IRIS comes up on its own.
- **Recovery episode (the mistake this recipe encodes):** deleting `IRIS.WIJ`
  after a clean stop makes IRIS believe the last shutdown was abnormal; the
  next start aborts journal restore with a stale-WIJ error and drops to
  single-user mode ("Startup aborted, entering single user mode"). Fixed with
  `iris session FHIR -B` → `Do ^STURECOV` → option **8** (reset system so
  journal is not restored at startup; pipes that WIJ-erase state), then a
  shutdown — `iris stop`/STURECOV option 3 refuse non-TTY prompts, so
  `iris force FHIR` was used to cycle it, and the reset made the next start
  boot straight to multi-user (abnormal-shutdown noted as a harmless alert).
  The wipe happened during packaging trims; the build script now hard-excludes
  WIJ/journals/ssh keys/`/var/log` dirs from trimming.
- **Re-verified after repack:** container restarted, direct TLS 200, ehr-shim
  8080 200, patient read through shim returns seed data, CRD doc-needed flag
  true (top-level `systemActions` non-empty on the warmup fixture),
  `state: warn` in `iris list` = benign HealthShare no-partner notice.
- **Open notes:** IRIS Health Community redistribution terms flagged in
  `LXC-DROPIN.md`; IRIS `_SYSTEM` password and the mock TLS key travel in the
  image (mock credentials by design); `machine-id` is duplicated per copy —
  acceptable for a demo image.