"""Black-box tests for the baseline-first matrix runner."""

from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = PROJECT_ROOT / "scripts" / "run_test_matrix.py"
CASE_IDS = (
    "hand_small",
    "zero",
    "positive_x",
    "negative_x",
    "random_1a2b3c4d",
    "random_31415926",
    "random_5eed1234",
    "random_c0ffee01",
    "random_deadbeef",
)


@dataclass(frozen=True)
class FakeSuite:
    """Hold the paths and controls for one subprocess-level fake suite."""

    root: Path
    reference: Path
    baseline_simulator: Path
    matrix_simulator: Path
    verifier: Path
    cases_root: Path
    results_root: Path
    baseline_expected: Path
    baseline_actual: Path
    log_path: Path


def _write_executable(path: Path, source: str) -> None:
    _ = path.write_text(source, encoding="utf-8")
    _ = path.chmod(0o755)


def _manifest(case_lines: tuple[str, ...]) -> str:
    return "\n".join(("format mamba_ssm_case_manifest_v1", *case_lines, ""))


def make_suite(
    tmp_path: Path,
    *,
    manifest: str | None = None,
    missing_file: str | None = None,
) -> FakeSuite:
    """Create executable fixtures that exercise the real subprocess contract."""
    root = tmp_path / "project"
    _ = root.mkdir()
    cases_root = root / "vectors" / "cases"
    results_root = root / "results" / "cases"
    baseline_expected = root / "vectors" / "expected.txt"
    _ = baseline_expected.parent.mkdir()
    _ = baseline_expected.write_text("baseline expected\n", encoding="utf-8")
    baseline_actual = root / "results" / "bluesim_output.txt"
    _ = baseline_actual.parent.mkdir()
    log_path = root / "commands.log"
    manifest_text = manifest or _manifest(
        tuple(f"case {case_id}" for case_id in CASE_IDS)
    )
    omitted_name = missing_file or ""

    reference = root / "reference.py"
    _write_executable(
        reference,
        f"""#!/usr/bin/env python3
import pathlib
import sys

log = pathlib.Path({str(log_path)!r})
previous = log.read_text(encoding='utf-8') if log.exists() else ''
entry = 'reference ' + ' '.join(sys.argv[1:]) + '\\n'
log.write_text(previous + entry, encoding='utf-8')
if len(sys.argv) == 3 and sys.argv[1] == '--cases-root':
    root = pathlib.Path(sys.argv[2])
    root.mkdir(parents=True, exist_ok=True)
    (root / 'manifest.txt').write_text({manifest_text!r}, encoding='utf-8')
    for line in {manifest_text!r}.splitlines()[1:]:
        fields = line.split()
        if len(fields) != 2 or fields[0] != 'case':
            continue
        case = root / fields[1]
        case.mkdir(parents=True, exist_ok=True)
        if {omitted_name!r} != 'input':
            (case / 'input.txt').write_text('input\\n', encoding='utf-8')
        if {omitted_name!r} != 'expected':
            (case / 'expected.txt').write_text('expected\\n', encoding='utf-8')
""",
    )
    baseline_simulator = root / "baseline.py"
    _write_executable(
        baseline_simulator,
        f"""#!/usr/bin/env python3
import pathlib

log = pathlib.Path({str(log_path)!r})
previous = log.read_text(encoding='utf-8') if log.exists() else ''
log.write_text(previous + 'baseline\\n', encoding='utf-8')
print('baseline')
""",
    )
    matrix_simulator = root / "matrix.py"
    _write_executable(
        matrix_simulator,
        f"""#!/usr/bin/env python3
import os
import pathlib
import signal
import sys

case = pathlib.Path.cwd().name
log = pathlib.Path({str(log_path)!r})
previous = log.read_text(encoding='utf-8') if log.exists() else ''
log.write_text(previous + f'matrix {{case}}\\n', encoding='utf-8')
if case in os.environ.get('HANG_CASES', '').split(','):
    signal.pause()
if case in os.environ.get('LOADER_ERROR_CASES', '').split(','):
    print('Error: failed to load input', file=sys.stderr)
if case in os.environ.get('LOADER_ERROR_STDOUT_CASES', '').split(','):
    print('Error: failed to load input')
if case in os.environ.get('NUMERIC_FAIL_CASES', '').split(','):
    print('bad')
else:
    print('ok')
sys.exit(9 if case in os.environ.get('SIMULATOR_FAIL_CASES', '').split(',') else 0)
""",
    )
    verifier = root / "verifier.py"
    _write_executable(
        verifier,
        f"""#!/usr/bin/env python3
import pathlib
import sys

actual = pathlib.Path(sys.argv[sys.argv.index('--actual') + 1])
log = pathlib.Path({str(log_path)!r})
entry = f'verify {{actual.name}}\\n'
previous = log.read_text(encoding='utf-8') if log.exists() else ''
log.write_text(previous + entry, encoding='utf-8')
print(f'VERIFIER {{actual.name}}')
sys.exit(1 if actual.read_text(encoding='utf-8').strip() == 'bad' else 0)
""",
    )
    return FakeSuite(
        root=root,
        reference=reference,
        baseline_simulator=baseline_simulator,
        matrix_simulator=matrix_simulator,
        verifier=verifier,
        cases_root=cases_root,
        results_root=results_root,
        baseline_expected=baseline_expected,
        baseline_actual=baseline_actual,
        log_path=log_path,
    )


def run_runner(
    suite: FakeSuite,
    environment: dict[str, str] | None = None,
    timeout_seconds: str = "2",
) -> subprocess.CompletedProcess[str]:
    """Invoke the runner through its CLI with temporary executable paths."""
    env = os.environ | (environment or {})
    return subprocess.run(
        [
            sys.executable,
            str(RUNNER),
            "--reference",
            str(suite.reference),
            "--baseline-simulator",
            str(suite.baseline_simulator),
            "--matrix-simulator",
            str(suite.matrix_simulator),
            "--verifier",
            str(suite.verifier),
            "--baseline-expected",
            str(suite.baseline_expected),
            "--baseline-actual",
            str(suite.baseline_actual),
            "--cases-root",
            str(suite.cases_root),
            "--results-root",
            str(suite.results_root),
            "--timeout-seconds",
            timeout_seconds,
        ],
        cwd=suite.root,
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
    )


def test_help_documents_all_path_and_executable_options() -> None:
    """The CLI exposes every configurable subprocess and data boundary."""
    completed = subprocess.run(
        [sys.executable, str(RUNNER), "--help"],
        text=True,
        capture_output=True,
        check=False,
    )

    assert completed.returncode == 0
    for option in (
        "--reference",
        "--baseline-simulator",
        "--matrix-simulator",
        "--verifier",
        "--baseline-expected",
        "--baseline-actual",
        "--cases-root",
        "--results-root",
        "--timeout-seconds",
    ):
        assert option in completed.stdout


def test_happy_path_runs_ten_flows_in_exact_order_and_captures_results(
    tmp_path: Path,
) -> None:
    """The baseline precedes deterministic case execution and all verdicts pass."""
    suite = make_suite(tmp_path)

    completed = run_runner(suite)

    assert completed.returncode == 0, completed.stderr
    verdicts = [
        line
        for line in completed.stdout.splitlines()
        if line.endswith(" PASS") or line.startswith("MATRIX ")
    ]
    assert verdicts == [
        *[f"{case_id} PASS" for case_id in CASE_IDS],
        "MATRIX PASS 9/9",
    ]
    assert suite.log_path.read_text(encoding="utf-8").splitlines() == [
        "reference ",
        "baseline",
        "verify bluesim_output.txt",
        f"reference --cases-root {suite.cases_root}",
        *[
            entry
            for case_id in CASE_IDS
            for entry in (f"matrix {case_id}", "verify bluesim_output.txt")
        ],
    ]
    for case_id in CASE_IDS:
        assert (suite.results_root / case_id / "bluesim_output.txt").read_text(
            encoding="utf-8"
        ) == "ok\n"


def test_baseline_verifier_failure_stops_before_case_generation(tmp_path: Path) -> None:
    """A failed legacy verdict is fail-fast and leaves matrix roots untouched."""
    suite = make_suite(tmp_path)
    _write_executable(
        suite.baseline_simulator,
        f"""#!/usr/bin/env python3
import pathlib

log = pathlib.Path({str(suite.log_path)!r})
log.write_text(log.read_text(encoding='utf-8') + 'baseline\\n', encoding='utf-8')
print('bad')
""",
    )

    completed = run_runner(suite)

    assert completed.returncode == 1
    assert "VERIFIER bluesim_output.txt" in completed.stdout
    assert "MATRIX" not in completed.stdout
    assert not suite.cases_root.exists()
    assert suite.log_path.read_text(encoding="utf-8").splitlines() == [
        "reference ",
        "baseline",
        "verify bluesim_output.txt",
    ]


def test_matrix_failures_continue_through_the_ninth_case(tmp_path: Path) -> None:
    """Simulator failures affect only their cases and do not stop later cases."""
    suite = make_suite(tmp_path)

    completed = run_runner(suite, {"SIMULATOR_FAIL_CASES": "zero,random_c0ffee01"})

    assert completed.returncode == 1
    verdicts = [
        line
        for line in completed.stdout.splitlines()
        if line.endswith((" PASS", " FAIL")) or line.startswith("MATRIX ")
    ]
    assert verdicts == [
        "hand_small PASS",
        "zero FAIL",
        "positive_x PASS",
        "negative_x PASS",
        "random_1a2b3c4d PASS",
        "random_31415926 PASS",
        "random_5eed1234 PASS",
        "random_c0ffee01 FAIL",
        "random_deadbeef PASS",
        "MATRIX FAIL 7/9",
    ]
    assert f"matrix {CASE_IDS[-1]}" in suite.log_path.read_text(encoding="utf-8")


@pytest.mark.parametrize(
    ("manifest", "missing_file", "message"),
    [
        ("not mamba_ssm_case_manifest_v1\n", None, "expected"),
        (
            _manifest(
                (
                    *tuple(f"case {case_id}" for case_id in CASE_IDS[:-1]),
                    "case hand_small",
                )
            ),
            None,
            "duplicate",
        ),
        (
            _manifest(
                (
                    *tuple(f"case {case_id}" for case_id in CASE_IDS[:-1]),
                    "case ../unsafe",
                )
            ),
            None,
            "unsafe",
        ),
        (
            _manifest(tuple(f"case {case_id}" for case_id in CASE_IDS[:-1])),
            None,
            "exactly",
        ),
        (
            _manifest(tuple(f"case {case_id}" for case_id in CASE_IDS)),
            "input",
            "input.txt",
        ),
        (
            _manifest(tuple(f"case {case_id}" for case_id in CASE_IDS)),
            "expected",
            "expected.txt",
        ),
    ],
)
def test_malformed_manifest_or_missing_case_file_fails_before_simulation(
    tmp_path: Path,
    manifest: str,
    missing_file: str | None,
    message: str,
) -> None:
    """Only the exact safe nine-case input contract reaches matrix simulation."""
    suite = make_suite(tmp_path, manifest=manifest, missing_file=missing_file)

    completed = run_runner(suite)

    assert completed.returncode == 2
    assert message in completed.stderr
    assert "matrix " not in suite.log_path.read_text(encoding="utf-8")


@pytest.mark.parametrize(
    "timeout_seconds",
    [
        pytest.param("inf"),
        pytest.param("nan"),
        pytest.param("0"),
        pytest.param("-1"),
    ],
)
def test_cli_rejects_non_finite_or_non_positive_timeout_before_any_child_runs(
    tmp_path: Path,
    timeout_seconds: str,
) -> None:
    """Reject deadline-disabling timeout values before the baseline starts."""
    suite = make_suite(tmp_path)

    completed = run_runner(suite, timeout_seconds=timeout_seconds)

    assert completed.returncode == 2
    assert "--timeout-seconds" in completed.stderr
    assert not suite.log_path.exists()


def test_positive_timeout_kills_hung_matrix_child_and_repeated_runs_clean_up(
    tmp_path: Path,
) -> None:
    """Each finite deadline kills its child and later cases run on every attempt."""
    first_root = tmp_path / "first"
    second_root = tmp_path / "second"
    _ = first_root.mkdir()
    _ = second_root.mkdir()
    suites = (make_suite(first_root), make_suite(second_root))

    for suite in suites:
        completed = run_runner(
            suite,
            {"HANG_CASES": "zero"},
            timeout_seconds="0.1",
        )
        assert completed.returncode == 1
        assert "zero FAIL" in completed.stdout
        assert "random_deadbeef PASS" in completed.stdout
        assert "MATRIX FAIL 8/9" in completed.stdout
        commands = suite.log_path.read_text(encoding="utf-8").splitlines()
        assert commands.count("matrix zero") == 1
        assert commands.count("matrix random_deadbeef") == 1


def test_loader_error_on_stderr_is_a_case_failure_even_with_zero_exit(
    tmp_path: Path,
) -> None:
    """Bluesim loader diagnostics cannot be mistaken for numeric success."""
    suite = make_suite(tmp_path)

    completed = run_runner(suite, {"LOADER_ERROR_CASES": "zero"})

    assert completed.returncode == 1
    assert "zero FAIL" in completed.stdout
    assert "MATRIX FAIL 8/9" in completed.stdout
    assert "Error: failed to load input" in completed.stderr


def test_loader_error_on_stdout_is_a_case_failure_even_with_zero_exit(
    tmp_path: Path,
) -> None:
    """Bluesim loader diagnostics in captured output cannot pass a matrix case."""
    suite = make_suite(tmp_path)

    completed = run_runner(suite, {"LOADER_ERROR_STDOUT_CASES": "zero"})

    assert completed.returncode == 1
    assert "zero FAIL" in completed.stdout
    assert "MATRIX FAIL 8/9" in completed.stdout


def test_stale_results_root_fails_before_matrix_simulation(tmp_path: Path) -> None:
    """An isolated matrix run cannot silently retain an old result capture."""
    suite = make_suite(tmp_path)
    _ = suite.results_root.mkdir(parents=True)
    _ = (suite.results_root / "stale.txt").write_text("stale\n", encoding="utf-8")

    completed = run_runner(suite)

    assert completed.returncode == 2
    assert "results root must be empty" in completed.stderr
    assert "matrix " not in suite.log_path.read_text(encoding="utf-8")
    assert (suite.results_root / "stale.txt").read_text(encoding="utf-8") == "stale\n"


def test_verifier_numeric_failure_is_a_case_failure_and_later_cases_run(
    tmp_path: Path,
) -> None:
    """The existing verifier's exit status is the only numeric verdict source."""
    suite = make_suite(tmp_path)

    completed = run_runner(suite, {"NUMERIC_FAIL_CASES": "positive_x"})

    assert completed.returncode == 1
    assert "positive_x FAIL" in completed.stdout
    assert "random_deadbeef PASS" in completed.stdout
    assert "MATRIX FAIL 8/9" in completed.stdout
