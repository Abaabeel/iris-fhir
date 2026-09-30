We ran the real HL7 DaVinci prior-authorization workflow — CRD → DTR → PAS — end to end, on InterSystems IRIS for Health as the FHIR engine, and shipped it as a drop-in lab anyone can run in ~25 minutes. No cloud. No PHI. A real browser walks from order → coverage card → OIDC login → questionnaire → claim → **PENDING → GRANTED**.

Why this matters:

• **Prior auth is the canary for healthcare interoperability.** 88% of it is still partly manual, and CMS-0057-F now forces FHIR R4 prior-auth APIs on payers by 2027/2028. The standards exist (DaVinci's CRD/DTR/PAS guides). What was missing was the whole loop *working* where you can watch it.

• **We proved IRIS for Health, we didn't just praise it.** Receipts: FHIR R4 CapabilityStatement over TLS, OAuth confidential client, seeded clinical data, checksum-verified drop-in image, cold boot to 200 in seconds — verified by two independent drivers (12/12 API + 14/14 browser).

• **To the InterSystems team** — this is a third-party, public, reproducible proof of your product as a FHIR engine, in the exact shape of a case study, plus a zero-friction on-ramp to try IRIS for Health Community. We'd welcome your eyes on it. (Credit yours, no redistribution, no trademark claims.)

• **To hospital-side digital health folks** — your payer-interoperability future, decompressed into one afternoon: CDS Hooks, SMART launch, DTR questionnaires, value sets, and a real multi-model clinical platform underneath. Plus the AI canvas: FHIR as substrate, hybrid deterministic-rule + LLM automation, and a local agent sandbox.

Run it yourself:

git clone https://github.com/Abaabeel/iris-fhir.git && cd iris-fhir
sudo bash bin/lxc-import.sh github
./bin/provision.sh --check && ./bin/up.sh
./bin/demo.sh && python3 bin/e2e-browser.py

Full write-up with the why, the receipts, and the walkthrough: https://github.com/Abaabeel/iris-fhir