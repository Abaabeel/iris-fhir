# The smallest machine that contains the whole future of prior authorization

**We ran the real HL7 DaVinci prior-authorization workflow — CRD → DTR → PAS —
end to end against InterSystems IRIS for Health as the FHIR engine, and
shipped the whole thing as a drop-in lab anyone can run in about 25 minutes.
No cloud. No PHI. No license request. Here is why we built it and what it
proves — for hospitals, for payers, and for the people who make IRIS.**

*Sep 30, 2026*

---

Every interoperability roadmap I have ever sat through ends with the same
slide: *"FHIR is coming."* Meanwhile, on the ground, prior authorization — the
gate between a prescription and a patient actually getting it — still runs on
faxes, portals, and phone queues. A widely cited study put **88% of
prior-authorization work as partially or entirely manual**. The system cost
has been estimated at **$23–31 billion a year**; the clinician hours vanish
into request forms. The future is always announced, but it is rarely *seen
working*.

So I did the thing nobody at those meetings had done: I built the smallest
machine that contains the whole loop, and I watched it work.

**One computer. One browser. One real prior-auth decision — `Pending` →
`Granted` — against a real InterSystems IRIS for Health FHIR server.**

## Prior authorization is the perfect canary

Prior auth is not exotic. It is the most routine, most bureaucratic
transaction in American healthcare — which is exactly why it is the canary for
the whole interoperability transition. If you can make prior auth work as
structured data, you can make anything work.

The regulator agrees. In January 2024 CMS finalized **CMS-0057-F**, requiring
Medicare Advantage plans, Medicaid managed care plans, and QHP issuers to
build a **Patient Access API**, a **Provider Access API**, and a **Prior
Authorization API** — all on **HL7 FHIR R4**, with compliance
deadlines of January **2027 for large payers** and January **2028 for small
payers**, a **72-hour urgent** decision window, and **real-time decisions** for
routinely approved items and services.

The standards answer to that regulation is the **HL7 DaVinci Project** and its
implementation guides:

- **CRD — Coverage Requirements Discovery.** At order time, a CDS hook asks
  the payer: *does this order have coverage or documentation requirements?*
  A card comes back.
- **DTR — Documentation Templates and Rules.** A SMART app retrieves the
  payer's questionnaire and CQL rules, pre-fills from the record, and turns
  the answers into structured FHIR.
- **PAS — Prior Authorization Support.** The request is submitted to the
  payer endpoint (`Claim/$submit`) and answered with a `ClaimResponse` —
  pending, granted, or denied.

Every piece of that is public, documented, and real. What was missing was the
**whole loop, running**, where you can watch each mechanism fire.

## What "the whole loop" is

In this lab you drive it with a real browser:

1. You pick a patient — `pat013`, Vlad Quinton, 69 — and order a home blood
   glucose monitor, then submit the order to CRD.
2. CRD evaluates coverage rules (CQL + value sets) and returns a card:
   *"Documentation Required — complete this order in DTR."*
3. Clicking the card launches DTR as a SMART app through a **real OIDC login**
   (Keycloak), and the payer's questionnaire renders with live value-set
   answer options.
4. You fill it, press **PROCEED TO PRIOR AUTH**, and DTR builds the `Claim`
   itself — the load-bearing detail nobody expects: the SMART app submits the
   claim, not the EHR.
5. `Claim/$submit` returns `201`; PAS evaluates and, after a deliberate 15
   seconds, the browser shows **`PENDING` → `GRANTED`**.

Two independent drivers verify it — an API driver (12 assertions) and a
real-browser driver (14 assertions) — because each covers a leg the other
cannot. Both are green. This is not a mockup of a workflow; it is the
workflow.

## Why InterSystems IRIS for Health as the engine

The obvious move would have been a stub FHIR server. We chose the opposite:
**InterSystems IRIS for Health** — a genuine production clinical-data platform,
with a native **FHIR R4 repository**, an HL7 v2/X12 integration engine, and
multi-model storage (objects + SQL + documents in one engine). It is the
spine of real hospital systems, and InterSystems has published enterprise
FHIR + AI success stories (Stanford Health Care) built on the same
capabilities.

Community Edition is free for evaluation and development. We **provisioned
it, seeded it, and proved it** — not with a brochure, but with receipts:

| What we proved about IRIS | The evidence |
|---|---|
| Serves FHIR R4 over TLS | `curl -sk https://10.0.3.108:52774/fhir/r4/metadata` returns the CapabilityStatement, 200 |
| OAuth-secured access | a confidential client is provisioned in the image; a shim mints a `client_credentials` bearer (`aud` = the FHIR base URL) per call |
| Real clinical data layer | DaVinci demo patients seeded into IRIS, served to the SMART questionnaire flow |
| Reliable enough to ship | the whole instance ships as a checksum-verified image; cold boot to TLS 200 in seconds; auto-start; clean shutdowns |
| End-to-end, twice | 12/12 API + 14/14 browser assertions drive claims to `GRANTED` against IRIS-backed data |

## The part that changes the story: the drop-in image

Anyone can *describe* a working FHIR stack. We made it **downloadable**: a
prebuilt LXC image of the fully provisioned IRIS for Health instance, released
publicly with whole-archive SHA-256 verification. An end user runs one
command:

```bash
git clone https://github.com/Abaabeel/iris-fhir.git
cd iris-fhir
sudo bash bin/lxc-import.sh github
```

Then the stack scripts (`provision.sh`, `up.sh`, `demo.sh`,
`e2e-browser.py`) bring up the six services, and half an hour later a
first-time user is watching a prior-auth claim get granted in the browser —
with IRIS doing the FHIR work underneath. No InterSystems account, no license
request, no install wizard, no cloud signup.

## To the people at InterSystems — this one is yours to enjoy

You build IRIS for Health and you say it is a FHIR engine. Fair enough — but
claims are cheap, and proofs are public. This project is an **independent,
reproducible, third-party proof** of your product doing exactly that, at the
hardest end: the live data spine of a complete prior-auth loop, driven to a
real decision in a real browser.

Specifically, it should interest you because:

- **It is a zero-friction way for people to try your product.** One command
  imports a fully provisioned IRIS for Health Community instance. That is
  developer-relations gold for a product with a normally heavier on-ramp.
- **It is a third-party case study in miniature.** Real FHIR R4, real OAuth,
  real clinical data — and, underneath, the AI-ready platform story:
  multi-model storage, SQL on FHIR, native vector search for RAG/GenAI on the
  same engine.
- **It is the other side of your own regulation.** InterSystems markets Payer
  Services around CMS-0057/CMS-9115 compliance. This repo proves the
  provider side of the same regulation talking to an IRIS FHIR server. Put
  them together and you own the whole story.
- **It is community-shaped.** MIT-licensed, pinned, checksum-verified, and
  documented for humans *and* AI agents.

We welcome your eyes on it: run it, break it, re-verify it. If it earns an
InterSystems Developer Community article or a case-study mention, that is
yours to write. (Boundary, honestly framed: the image is the product verbatim
under InterSystems' Community licence — no InterSystems code is
redistributed, and no trademark claim is made. The credit is yours; the proof
is ours to give.)

## What is in it for you, hospital-side

If you run HIS in a hospital, this is your payer-interoperability future
decompressed into a single afternoon:

- *"What does an order-time coverage check look like?"* — the CRD card on the
  coverage request.
- *"How does a SMART app launch inside an EHR?"* — the real OIDC redirect
  through Keycloak when you click the card.
- *"What is a payer questionnaire / DTR / value set?"* — rendered live, with
  seeded terminology from public sources.
- *"How does a prior-auth request reach a payer as data?"* — DTR builds the
  `Claim`; `Claim/$submit` returns `201`; `PENDING → GRANTED`.

Under one roof you get the actual building blocks of the FHIR-based hospital:
FHIR R4 resources and CapabilityStatements, SMART OAuth, CDS Hooks,
terminology management, and a real multi-model clinical data platform behind
it all. Knowing FHIR on paper and having watched it work are different
things. This repo is the second one.

## And the AI canvas

Four honest reasons this lab is the right place to think about AI in
healthcare:

1. **FHIR is the substrate AI needs.** Chart summarisation, prior-auth
   copilots, RAG over patient records — every LLM feature is only as good as
   the structured, queryable data underneath. This lab hands you a running
   example of that substrate.
2. **Prior auth is one of AI's highest-value targets.** Voluminous,
   paper-bound, rule-documented — the perfect case for retrieval + drafting +
   verification: an assistant that drafts questionnaire answers, pulls the
   supporting codes, and generates the attachment, with a clinician signing
   off.
3. **Deterministic rules are the guardrail, not the enemy.** DaVinci decides
   with CQL + value sets — auditable, explainable. The realistic architecture
   is hybrid: LLMs draft, rules adjudicate. This lab gives you both halves.
4. **Agents need tool access — and FHIR is the tool surface.** This
   environment is a sandbox where an agent can exercise CRD, DTR, PAS, and an
   IRIS FHIR server end to end, locally, with synthetic data only. The repo
   even ships an agent playbook.

## Run it

```bash
git clone https://github.com/Abaabeel/iris-fhir.git
cd iris-fhir
sudo bash bin/lxc-import.sh github     # the IRIS image, verified
./bin/provision.sh --check             # all inputs present
./bin/up.sh                            # six services, post-flight checks
./bin/demo.sh                          # 12/12 API assertions
python3 bin/e2e-browser.py             # 14/14 real-browser assertions
# open http://localhost:3001/ and click through to a GRANTED claim
```

Or just read the [full README](https://github.com/Abaabeel/iris-fhir) — it
carries the why, the what, the install, the walkthrough, and the traps.

The FHIR future is not coming. It is here, it runs on one machine, and its
engine is InterSystems IRIS for Health. **You can watch it grant a claim in
half an hour.**