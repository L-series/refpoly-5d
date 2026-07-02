# refpoly-5d — pipeline foundation targets.
#
# Phase 0 (current): correctness golden gate + benchmark harness built on the
# PALP poly.x oracle. Phase 1 will add classifier build/test targets that reuse
# the same golden fixture.

PY ?= python3

.PHONY: test golden bench bench-update corpus help

help:
	@echo "make test          - run the NF/hash golden regression gate"
	@echo "make golden        - regenerate tests/fixtures/golden_nf.jsonl (oracle)"
	@echo "make corpus        - regenerate corpora from the source sample"
	@echo "make bench         - run WS->NF->hash benchmark (no baseline write)"
	@echo "make bench-update  - run benchmark and update bench/baseline.json"
	@echo "make bench-check   - run benchmark and fail on regression vs baseline"

test:
	$(PY) tests/test_nf_golden.py

golden:
	$(PY) tests/gen_golden.py

corpus:
	$(PY) tests/curate_corpus.py

bench:
	$(PY) bench/bench_nf.py

bench-update:
	$(PY) bench/bench_nf.py --update

bench-check:
	$(PY) bench/bench_nf.py --check
