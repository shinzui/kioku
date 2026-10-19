# Bundle Update Log

## 2026-10-19

* **Status change**: Accept IR-7 after source and ADR validation; link ExecPlan 50 and its intention. Scope the change to a deprecated legacy-only archive receipt bridge with unchanged attribution, authorization boundaries and typed outcomes. Implementation and publication remain pending.
* **Status change**: Accept IR-6 after Kioku source and architecture validation; link ExecPlan 49 and record fixed-field metadata, tag cursor, ordering, PVP and catalog-adoption clarifications. Implementation and publication remain pending.
* **Addition**: IR-6 requests fixed Memory metadata, separate tag pages, recency and scope-kind queries against released Kioku 0.10.0.0; IR-7 separately requests truthful archive receipts for existing unattributed hosts. Both remain proposed; implementation and publication are separate.

## 2026-09-08

* **Migration**: Move the bundle to OKF 0.2 on the `coordination.improvementRequests`
  profile from okf-profiles v0.14.0. Every request gains a `generated` block naming the
  author and the revision time it already recorded; the superseded `timestamp` key is
  retained, which the profile reads as the v0.1 fallback. Adds the generated `index.md`
  declaring `okf_version: "0.2"`, which the profile now requires.
* **Update**: IR-1 records a `resolution`, lifted from the completion evidence already in
  its body, now that the profile asks a terminal request for one.
* **Fix**: Reorder the dated sections newest first; the 2026-08-06 section sat below
  2026-07-30.

## 2026-08-10

* **Register**: Adopt the shared improvement-request profile and expose the existing
  IR-1 through IR-5 corpus through Mori's cross-project concept index.

## 2026-08-06

* **Addition**: IR-3 requests versioned learned Skills with trusted derivation, review,
  immutable versions, provenance, resource integrity, and memory-space authorization.
* **Addition**: IR-4 requests an optional authenticated HTTP service composed with Shomei,
  Meibo, and En and backed by a versioned OpenAPI contract.
* **Addition**: IR-5 requests supported TypeScript and Python SDKs generated from the HTTP
  service contract with safe retries and cross-language conformance.
* **Revision**: IR-2 now requires partition-first queries and the explicit recall-target API.

## 2026-07-30

* **Addition**: IR-1 requests a Kioku release compatible with Keiki 0.4 and Keiro 0.4.
* **Addition**: IR-2 requests indexed subject-reference session lookup and SQL-bounded memory
  read models.
* **Status change**: IR-1 is completed by Kioku `v0.2.0.0`; its five packages are
  published on Hackage and admit the Keiki 0.4 / Keiro 0.4 cohort.
