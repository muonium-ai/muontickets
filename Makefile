SHELL := /bin/sh

PY := .venv/bin/python

.PHONY: test test-conformance benchmark-smoke benchmark-1000 compare-generated

test: test-conformance

test-conformance:
	$(PY) -m unittest \
		tests.test_conformance_runner.ConformanceRunnerTests.test_core_workflow_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_reporting_graph_pick_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_options_parity_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_pick_scoring_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_zig_reporting_graph_pick_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_zig_options_parity_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_zig_pick_scoring_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_rust_core_workflow_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_rust_reporting_graph_pick_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_rust_options_parity_fixture \
		tests.test_conformance_runner.ConformanceRunnerTests.test_rust_pick_scoring_fixture

benchmark-smoke:
	$(PY) tools/perf_1000/benchmark_ticket_lifecycle.py --count 30

benchmark-1000:
	$(PY) tools/perf_1000/benchmark_ticket_lifecycle.py --count 1000

compare-generated:
	$(PY) tools/perf_1000/compare_generated_tickets.py
