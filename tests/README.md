# tests/ — normal-form correctness foundation

Golden regression gate for the WS → normal form → hash path, built **before**
the C++ pipeline is ported so every future change is checked against a frozen
ground truth. No external data needed: the fixtures are committed.

## Layout

| file | role |
|---|---|
| `palp_oracle.py` | runs weight systems through the committed PALP `poly.x -N` (the same NF code the classifier links) and parses the canonical vertex matrices |
| `nf_hash.py` | the **canonical hash-input byte layout** (int64-LE, row-major, `dim`×`nv` — matches `classifier.cpp::hash_normal_form`) + a pluggable registry of hash algorithms (`sha256`, `blake2b128`, and `xxh3_128` if the `xxhash` module is present) |
| `curate_corpus.py` | regenerates the committed corpora from `../process-polytopes/samples/sample-100k.txt` (deterministic, size-stratified) |
| `gen_golden.py` | freezes `fixtures/golden_nf.jsonl`: per WS the NF matrix, byte length, and digests |
| `test_nf_golden.py` | the gate: oracle reproduces every golden NF, digests unchanged, all algos deterministic |
| `fixtures/corpus_small.txt` | 400 size-stratified weight systems (points 21…13k) |
| `fixtures/golden_nf.jsonl` | frozen NFs + digests |

## Run

```bash
make test          # or: python3 tests/test_nf_golden.py
```

## The contract this pins

The NF **matrix** is tool-independent ground truth. The digests pin the exact
bytes that get hashed, so when the classifier is ported (Phase 1) it is gated on
(a) reproducing the matrix and (b) hashing the identical byte layout. Swapping
the hash algorithm is a policy change in `nf_hash.py`; it cannot silently change
what counts as the same polytope.

To gate a ported classifier, extend `test_nf_golden.py`'s `--classifier` hook so
the binary's `(nv, hash)` per WS is compared to the golden values.

## Regenerating (only when intentionally changing the oracle/corpus)

```bash
make corpus        # rebuild corpus_small.txt + bench corpus from the sample
make golden        # rebuild golden_nf.jsonl from the oracle
```
