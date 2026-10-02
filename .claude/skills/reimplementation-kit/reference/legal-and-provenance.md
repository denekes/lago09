# Legal notes, clean-room rules and provenance policy

> Licence note: Lago's lago-api is published under the GNU Affero General Public License v3.0 (AGPL-3.0). This kit
> describes its behaviour at pin `591ae90` (and the Lago events-processor at tree `83e012866f29`) in neutral form.
> This chapter is not legal advice: a proprietary rebuild needs review by counsel.

<!-- evidence-check: off policy chapter; facts about licences are stated with their source in Provenance -->

## 1. What the kit contains, and what it does not

| Kit content | Nature | Copied from the reference? |
|---|---|---|
| Behaviour chapters (rules, formulas, tables, state machines, fresh pseudocode) | description of observable behaviour, written for the kit | no source text, no comments, no identifiers beyond public API and wire names |
| Unit vectors and scenarios | input → expected output data; the expected values were produced by running the reference (or recomputed) | values only; many inputs are modelled on the reference's own test examples |
| Schemas, runners, reference adapter, self-tests | kit tooling written for the kit | no |
| Maintainer tooling (`scripts/maintainer/`, `maintainer-data/`, `reference/maintainer-oracle.md`) | runs the reference to mint and check vectors | invokes reference code at run time; never distributed in clean-room packs |

Wire-level names (REST paths, JSON field names, webhook types, error codes, Kafka topic and environment-variable
names) are kept verbatim because interoperability and the conformance vectors depend on them.

## 2. Rules for kit authors ("dirty room")

1. Describe behaviour, not code: formulas, decision tables, state machines and pseudocode written fresh from the
   behaviour and the vectors. Never transliterate Ruby, Go or SQL, never paste comments, never reproduce the
   reference's class, method or variable names in normative text.
2. Cite the reference (`$API/<path>:<line> @591ae90`, `events-processor/<path>:<line>`) only in a chapter's
   "Provenance (maintainers)" section and in a vector's `evidence.ref`. Implementers never need those citations.
3. No planning-document ids, investigation-note ids or scratch paths in kit text (the validator rejects them).
4. Every chapter starts with a licence note pointing here.
5. Evidence honesty: a vector is EXECUTED only when its expected value came from running the reference at the pin
   (or the Go reference for the events-processor); otherwise RECOMPUTED or EXTRACTED (`vector-format.md` §5).

## 3. Rules for implementers ("clean room")

1. Use the clean-room pack only (`acceptance-and-grading.md` §4): the three kit skills without maintainer parts.
2. Do not read, search for or clone the reference source (lago-api, lago-front, the umbrella repository, the
   events-processor). Do not use the reference's documentation beyond what the kit quotes.
3. Do not derive lookup tables from `expected` values; implement the rules. The maintainer holdout detects
   overfitting.
4. Log every gap (`KIT-GAPS.md`): the question, where you looked, the assumption you made.
5. Dependencies: use libraries under licences your project accepts. The kit specifies the expression language so a
   rebuild does not need the reference's expression engine (KQ-7: its licence is not stated in the copy the kit was
   built from; do not embed it without legal clearance).

## 4. Licences involved

| Component | Licence | Relevance |
|---|---|---|
| lago-api (pinned) | AGPL-3.0 | behaviour source of the billing chapters and vectors |
| Lago events-processor (umbrella repository) | AGPL-3.0 (repository licence) | behaviour source of the events-processor spec and goldens |
| lago-expression (expression engine) | not stated in the inspected checkout | KQ-7: specify, do not embed |
| The kit (text, vectors, tooling) | the umbrella repository's licence unless the owner decides otherwise | KQ-8: owner + legal decide the kit's own licence for proprietary use |

Open questions for the owner and counsel (KQ-8): whether behavioural data extracted by running AGPL software may
be used in a proprietary implementation; whether the kit authors' exposure to the source requires additional
separation (the authors are the "dirty room"; implementers see only the pack).

## 5. Provenance policy

- **Pins.** Every vector records `pin` (`591ae9005110` for billing areas, `ep:83e012866f29` for `ep`) and the
  runtime that produced the value. Chapters state their facts "as of" the same pins.
- **Traceability.** `scripts/maintainer/vector-provenance.py` checks that every `evidence.ref` resolves at its pin
  (file exists, line in range; events-processor refs through git at the tree) and lists the non-EXECUTED residue.
- **Re-minting.** A pin bump re-runs every vector against the oracle at the new pin; differences are triaged as
  behaviour change (update vector and chapter, record the change) or kit defect (`maintainer-oracle.md` §6).
- **Corrected twins** are RECOMPUTED by definition and cite their RBD; they change only when the owner rules.
- **Packs** are reproducible: `kit-pack.sh` writes a deterministic tarball (sorted names, zero mtimes) and prints
  its sha256; `kit.json` lists the sha256 of every file.

## Provenance (maintainers)

- AGPL-3.0 for lago-api: `$API/LICENSE:1` @591ae90 (GNU AFFERO GENERAL PUBLIC LICENSE, Version 3); the umbrella
  repository that holds the events-processor carries the same licence text (`LICENSE:1`, checked 2026-10-02).
- lago-expression licence: no LICENSE file and no licence field in the inspected copy (kit plan of record KQ-7,
  2026-10-02); re-check on every lago-expression bump.
- Clean-room isolation option A (pack-only branch) decided by the owner on 2026-10-02.
- Update triggers: an owner or counsel decision on KQ-7/KQ-8, a licence change upstream, a change of the pack layout.
