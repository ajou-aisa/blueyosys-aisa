"""Black-box tests for the result-only Bluesim matrix testbench."""

from __future__ import annotations

import hashlib
import re
import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
MATRIX_BINARY = PROJECT_ROOT / "build/matrix/tb_selective_ssm_matrix"
PROTECTED_HASHES = {
    PROJECT_ROOT / "bsv/SelectiveSSM.bsv": (
        "783f20a07efd0990801f532d6891150e55d36e81d3fead40ba576179b09bfeee"
    ),
    PROJECT_ROOT / "bsv/TbSelectiveSSM.bsv": (
        "822fcaa8efecd7596f413541b161f338da3614a64e39f6a9e7d6b44ec9179fd7"
    ),
}
ZERO_INPUT = "0\n" * 16
NONZERO_INPUT = "65536\n0\n0\n0\n" + "0\n" * 12
OUTPUT_PATTERN = re.compile(
    "\n".join(
        (
            r"calculated_new_state_q16 (-?\d+) (-?\d+) (-?\d+) (-?\d+)",
            r"calculated_y_q16 (-?\d+) (-?\d+)",
            "",
        ),
    ),
)


def run_matrix(case_dir: Path) -> subprocess.CompletedProcess[str]:
    """Run the simulator from an isolated case directory."""
    return subprocess.run(
        [str(MATRIX_BINARY)],
        cwd=case_dir,
        text=True,
        capture_output=True,
        check=False,
        timeout=10,
    )


def parse_result(output: str) -> tuple[int, int, int, int, int, int]:
    """Require exactly the two result records and their six signed values."""
    match = OUTPUT_PATTERN.fullmatch(output)
    assert match is not None, output
    return (
        int(match.group(1)),
        int(match.group(2)),
        int(match.group(3)),
        int(match.group(4)),
        int(match.group(5)),
        int(match.group(6)),
    )


def test_matrix_testbench_reads_its_cwd_input_and_prints_only_six_values(
    tmp_path: Path,
) -> None:
    """A zero case produces exactly four state and two output zeros."""
    assert MATRIX_BINARY.is_file(), "matrix simulator has not been built"
    _ = (tmp_path / "input.txt").write_text(ZERO_INPUT, encoding="utf-8")

    result = run_matrix(tmp_path)

    assert result.returncode == 0, result.stderr
    assert parse_result(result.stdout) == (0, 0, 0, 0, 0, 0)


def test_matrix_testbench_does_not_reuse_results_between_case_directories(
    tmp_path: Path,
) -> None:
    """Each invocation must load the relative input.txt in its own cwd."""
    assert MATRIX_BINARY.is_file(), "matrix simulator has not been built"
    zero_case = tmp_path / "zero"
    nonzero_case = tmp_path / "nonzero"
    zero_case.mkdir()
    nonzero_case.mkdir()
    _ = (zero_case / "input.txt").write_text(ZERO_INPUT, encoding="utf-8")
    _ = (nonzero_case / "input.txt").write_text(NONZERO_INPUT, encoding="utf-8")

    zero_result = run_matrix(zero_case)
    nonzero_result = run_matrix(nonzero_case)

    assert zero_result.returncode == nonzero_result.returncode == 0
    assert parse_result(zero_result.stdout) == (0, 0, 0, 0, 0, 0)
    assert parse_result(nonzero_result.stdout) != (0, 0, 0, 0, 0, 0)


def test_matrix_testbench_missing_or_malformed_input_is_not_a_success(
    tmp_path: Path,
) -> None:
    """Input-loading failures must not resemble a valid result-only run."""
    assert MATRIX_BINARY.is_file(), "matrix simulator has not been built"
    malformed_case = tmp_path / "malformed"
    malformed_case.mkdir()
    _ = (malformed_case / "input.txt").write_text("not-an-integer\n", encoding="utf-8")

    for case_dir in (tmp_path, malformed_case):
        result = run_matrix(case_dir)
        assert result.returncode != 0 or "Error:" in result.stdout + result.stderr


def test_matrix_testbench_zero_runs_are_repeatable_and_protected_files_are_clean(
    tmp_path: Path,
) -> None:
    """Repeated cases are deterministic and the legacy BSV files remain unchanged."""
    assert MATRIX_BINARY.is_file(), "matrix simulator has not been built"
    _ = (tmp_path / "input.txt").write_text(ZERO_INPUT, encoding="utf-8")

    first_result = run_matrix(tmp_path)
    second_result = run_matrix(tmp_path)

    assert first_result.returncode == second_result.returncode == 0
    assert parse_result(first_result.stdout) == parse_result(second_result.stdout)
    for path, expected_hash in PROTECTED_HASHES.items():
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected_hash
