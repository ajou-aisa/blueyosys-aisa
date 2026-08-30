# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "typing-extensions>=4.12",
#   "typer>=0.15,<1",
# ]
# ///
"""Run the legacy baseline before the fixed nine-case CPU-to-Bluesim matrix."""

from __future__ import annotations

import asyncio
import math
import os
import sys
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Final, NoReturn, Self

import typer
from typing_extensions import override

PROJECT_ROOT: Final = Path(__file__).resolve().parent.parent
REFERENCE_PATH: Final = PROJECT_ROOT / "build" / "ssm_reference"
BASELINE_SIMULATOR_PATH: Final = PROJECT_ROOT / "build" / "tb_selective_ssm"
MATRIX_SIMULATOR_PATH: Final = (
    PROJECT_ROOT / "build" / "matrix" / "tb_selective_ssm_matrix"
)
VERIFIER_PATH: Final = PROJECT_ROOT / "scripts" / "verify.py"
BASELINE_EXPECTED_PATH: Final = PROJECT_ROOT / "vectors" / "expected.txt"
BASELINE_ACTUAL_PATH: Final = PROJECT_ROOT / "results" / "bluesim_output.txt"
CASES_ROOT: Final = PROJECT_ROOT / "vectors" / "cases"
RESULTS_ROOT: Final = PROJECT_ROOT / "results" / "cases"
MANIFEST_FORMAT: Final = "format mamba_ssm_case_manifest_v1"
RECORD_FIELD_COUNT: Final = 2
CASE_IDS: Final = (
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
LOADER_ERROR_MARKER: Final = "Error:"
HELP_TEXT: Final = """Usage: run_test_matrix.py [OPTIONS]

Run the legacy baseline before the fixed nine-case matrix.

Options:
  --reference PATH            CPU reference executable.
  --baseline-simulator PATH   Legacy Bluesim executable.
  --matrix-simulator PATH     Result-only matrix Bluesim executable.
  --verifier PATH             Existing numeric verifier script or executable.
  --baseline-expected PATH    Legacy CPU expected-output file.
  --baseline-actual PATH      Legacy Bluesim captured-output file.
  --cases-root PATH           Generated root containing manifest.txt.
  --results-root PATH         Root for isolated matrix Bluesim outputs.
  --timeout-seconds FLOAT     Positive finite per-subprocess timeout.
  --help                      Show this message and exit."""


@dataclass(frozen=True, slots=True)
class CommandResult:
    """Capture one bounded subprocess result without discarding diagnostics."""

    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True, slots=True)
class MatrixCase:
    """Describe one validated matrix case directory."""

    identifier: str
    directory: Path
    expected_path: Path


@dataclass(frozen=True, slots=True)
class RunnerConfig:
    """Hold all configurable executable and filesystem boundaries."""

    reference: Path
    baseline_simulator: Path
    matrix_simulator: Path
    verifier: Path
    baseline_expected: Path
    baseline_actual: Path
    cases_root: Path
    results_root: Path
    timeout_seconds: float


PathOptionSetter = Callable[[RunnerConfig, Path], RunnerConfig]
PATH_OPTION_SETTERS: Final[dict[str, PathOptionSetter]] = {
    "--reference": lambda config, value: replace(config, reference=value),
    "--baseline-simulator": lambda config, value: replace(
        config,
        baseline_simulator=value,
    ),
    "--matrix-simulator": lambda config, value: replace(
        config,
        matrix_simulator=value,
    ),
    "--verifier": lambda config, value: replace(config, verifier=value),
    "--baseline-expected": lambda config, value: replace(
        config,
        baseline_expected=value,
    ),
    "--baseline-actual": lambda config, value: replace(
        config,
        baseline_actual=value,
    ),
    "--cases-root": lambda config, value: replace(config, cases_root=value),
    "--results-root": lambda config, value: replace(config, results_root=value),
}


@dataclass(frozen=True, slots=True)
class MatrixInputError(Exception):
    """Describe a manifest or matrix input contract violation."""

    detail: str

    @override
    def __str__(self) -> str:
        """Render the human-readable input contract failure."""
        return self.detail

    @classmethod
    def unreadable(cls, path: Path, error: OSError) -> Self:
        """Create an unreadable-manifest failure."""
        return cls(f"cannot read {path}: {error}")

    @classmethod
    def bad_format(cls, path: Path) -> Self:
        """Create an unexpected-manifest-format failure."""
        return cls(f"{path}: expected {MANIFEST_FORMAT!r}")

    @classmethod
    def malformed_record(cls, path: Path, line_number: int) -> Self:
        """Create a malformed-record failure."""
        return cls(f"{path}:{line_number}: malformed record")

    @classmethod
    def unsafe_identifier(cls, path: Path, line_number: int, identifier: str) -> Self:
        """Create an unsafe-identifier failure."""
        return cls(f"{path}:{line_number}: unsafe case identifier {identifier!r}")

    @classmethod
    def duplicate_identifier(
        cls,
        path: Path,
        line_number: int,
        identifier: str,
    ) -> Self:
        """Create a duplicate-identifier failure."""
        return cls(f"{path}:{line_number}: duplicate case identifier {identifier!r}")

    @classmethod
    def wrong_count(cls, path: Path) -> Self:
        """Create a case-count failure."""
        return cls(f"{path}: expected exactly {len(CASE_IDS)} case records")

    @classmethod
    def wrong_order(cls, path: Path) -> Self:
        """Create a fixed-scope-order failure."""
        return cls(f"{path}: case IDs must match the fixed scope order")

    @classmethod
    def missing_directory(cls, path: Path) -> Self:
        """Create a missing safe case-directory failure."""
        return cls(f"{path}: missing safe case directory")

    @classmethod
    def missing_input(cls, path: Path) -> Self:
        """Create a missing case-input failure."""
        return cls(f"{path}: missing case input.txt")

    @classmethod
    def missing_expected(cls, path: Path) -> Self:
        """Create a missing case-expected failure."""
        return cls(f"{path}: missing case expected.txt")

    @classmethod
    def stale_results_root(cls, path: Path) -> Self:
        """Create an isolated-results-root failure."""
        return cls(f"{path}: results root must be empty")


def _as_text(value: str | bytes | None) -> str:
    """Normalize subprocess exception streams for lossless reporting."""
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value or ""


async def _run_command(
    command: list[str],
    cwd: Path,
    timeout_seconds: float,
) -> CommandResult:
    """Capture one subprocess asynchronously and terminate it on timeout."""
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as error:
        return CommandResult(127, "", f"{command[0]}: {error}\n")

    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout_seconds)
    except TimeoutError:
        process.kill()
        stdout, stderr = await process.communicate()
        return CommandResult(124, _as_text(stdout), _as_text(stderr))
    returncode = await process.wait()
    return CommandResult(returncode, _as_text(stdout), _as_text(stderr))


def run_command(command: list[str], cwd: Path, timeout_seconds: float) -> CommandResult:
    """Execute one command with captured streams and a bounded duration."""
    return asyncio.run(_run_command(command, cwd, timeout_seconds))


def _relay_stderr(result: CommandResult) -> None:
    """Forward a child diagnostic stream without changing its content."""
    if result.stderr:
        typer.echo(result.stderr, nl=False, err=True)


def _relay_stdout(result: CommandResult) -> None:
    """Forward a child report stream without changing its content."""
    if result.stdout:
        typer.echo(result.stdout, nl=False)


def _verifier_command(verifier: Path, expected: Path, actual: Path) -> list[str]:
    """Build a command for either the project script or an executable fixture."""
    if os.access(verifier, os.X_OK):
        prefix = [str(verifier)]
    else:
        prefix = [sys.executable, str(verifier)]
    return [*prefix, "--expected", str(expected), "--actual", str(actual)]


def _is_safe_component(identifier: str) -> bool:
    """Accept only one non-special portable path component."""
    return (
        bool(identifier)
        and identifier not in {".", ".."}
        and "/" not in identifier
        and "\\" not in identifier
        and Path(identifier).name == identifier
    )


def _read_manifest(cases_root: Path) -> tuple[Path, list[str]]:
    """Read the manifest without allowing a missing file to escape as OSError."""
    manifest_path = cases_root / "manifest.txt"
    try:
        return manifest_path, manifest_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise MatrixInputError.unreadable(manifest_path, error) from error


def _parse_identifiers(manifest_path: Path, lines: list[str]) -> tuple[str, ...]:
    """Parse exact ordered records and reject every unlisted manifest shape."""
    if not lines or lines[0] != MANIFEST_FORMAT:
        raise MatrixInputError.bad_format(manifest_path)

    identifiers: list[str] = []
    for line_number, line in enumerate(lines[1:], start=RECORD_FIELD_COUNT):
        fields = line.split()
        if len(fields) != RECORD_FIELD_COUNT or fields[0] != "case":
            raise MatrixInputError.malformed_record(manifest_path, line_number)
        identifier = fields[1]
        if not _is_safe_component(identifier):
            raise MatrixInputError.unsafe_identifier(
                manifest_path,
                line_number,
                identifier,
            )
        if identifier in identifiers:
            raise MatrixInputError.duplicate_identifier(
                manifest_path,
                line_number,
                identifier,
            )
        identifiers.append(identifier)

    if len(identifiers) != len(CASE_IDS):
        raise MatrixInputError.wrong_count(manifest_path)
    if tuple(identifiers) != CASE_IDS:
        raise MatrixInputError.wrong_order(manifest_path)
    return tuple(identifiers)


def _validate_cases(
    cases_root: Path,
    identifiers: tuple[str, ...],
) -> tuple[MatrixCase, ...]:
    """Require each fixed case's safe directory, input, and CPU expected output."""
    root = cases_root.resolve()
    cases: list[MatrixCase] = []
    for identifier in identifiers:
        directory = cases_root / identifier
        if not directory.is_dir() or not directory.resolve().is_relative_to(root):
            raise MatrixInputError.missing_directory(directory)
        input_path = directory / "input.txt"
        expected_path = directory / "expected.txt"
        if not input_path.is_file():
            raise MatrixInputError.missing_input(input_path)
        if not expected_path.is_file():
            raise MatrixInputError.missing_expected(expected_path)
        cases.append(MatrixCase(identifier, directory, expected_path))
    return tuple(cases)


def parse_manifest(cases_root: Path) -> tuple[MatrixCase, ...]:
    """Validate the exact fixed manifest without discovering files by globbing."""
    manifest_path, lines = _read_manifest(cases_root)
    identifiers = _parse_identifiers(manifest_path, lines)
    return _validate_cases(cases_root, identifiers)


def _validate_results_root(results_root: Path) -> None:
    """Require a fresh output root so no stale capture can be mistaken as current."""
    if results_root.exists() and (
        not results_root.is_dir() or any(results_root.iterdir())
    ):
        raise MatrixInputError.stale_results_root(results_root)


def _run_verifier(config: RunnerConfig, expected: Path, actual: Path) -> CommandResult:
    """Run the existing verifier and relay its report and diagnostics."""
    result = run_command(
        _verifier_command(config.verifier, expected, actual),
        PROJECT_ROOT,
        config.timeout_seconds,
    )
    _relay_stdout(result)
    _relay_stderr(result)
    return result


def _baseline_passes(config: RunnerConfig) -> bool:
    """Run the legacy CPU, simulator, and verifier chain before matrix creation."""
    reference_result = run_command(
        [str(config.reference)],
        PROJECT_ROOT,
        config.timeout_seconds,
    )
    _relay_stderr(reference_result)
    if reference_result.returncode != 0:
        return False

    simulator_result = run_command(
        [str(config.baseline_simulator)],
        PROJECT_ROOT,
        config.timeout_seconds,
    )
    _ = config.baseline_actual.parent.mkdir(parents=True, exist_ok=True)
    _ = config.baseline_actual.write_text(simulator_result.stdout, encoding="utf-8")
    _relay_stderr(simulator_result)
    verifier_result = _run_verifier(
        config,
        config.baseline_expected,
        config.baseline_actual,
    )
    return (
        simulator_result.returncode == 0
        and LOADER_ERROR_MARKER not in simulator_result.stdout
        and LOADER_ERROR_MARKER not in simulator_result.stderr
        and verifier_result.returncode == 0
    )


def _default_config() -> RunnerConfig:
    """Return the project-local executable and filesystem defaults."""
    return RunnerConfig(
        REFERENCE_PATH,
        BASELINE_SIMULATOR_PATH,
        MATRIX_SIMULATOR_PATH,
        VERIFIER_PATH,
        BASELINE_EXPECTED_PATH,
        BASELINE_ACTUAL_PATH,
        CASES_ROOT,
        RESULTS_ROOT,
        30.0,
    )


def _print_help() -> None:
    """Document every configurable CLI boundary without accepting loose arguments."""
    typer.echo(HELP_TEXT)


def _cli_error(detail: str) -> NoReturn:
    """Report an invalid CLI boundary and exit with the conventional usage code."""
    typer.echo(detail, err=True)
    raise typer.Exit(code=2)


def _parse_timeout(value: str) -> float:
    """Parse and bound the per-subprocess timeout CLI value."""
    try:
        timeout_seconds = float(value)
    except ValueError:
        _cli_error(f"invalid timeout value {value!r}")
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 0.0:
        _cli_error("--timeout-seconds must be finite and greater than 0")
    return timeout_seconds


def _parse_cli(arguments: list[str]) -> RunnerConfig:
    """Parse only documented option-value pairs into a fully typed runner config."""
    config = _default_config()
    index = 0
    while index < len(arguments):
        option = arguments[index]
        if option == "--help":
            _print_help()
            raise typer.Exit(code=0)
        if not option.startswith("--"):
            _cli_error(f"unexpected argument {option!r}")
        if index + 1 == len(arguments):
            _cli_error(f"missing value for {option}")
        value = arguments[index + 1]
        if option == "--timeout-seconds":
            config = replace(config, timeout_seconds=_parse_timeout(value))
        else:
            setter = PATH_OPTION_SETTERS.get(option)
            if setter is None:
                _cli_error(f"unknown option {option!r}")
            config = setter(config, Path(value))
        index += RECORD_FIELD_COUNT
    return config


def run_matrix(config: RunnerConfig) -> None:
    """Run baseline first, then aggregate all fixed matrix case verdicts."""
    if not _baseline_passes(config):
        raise typer.Exit(code=1)

    generation_result = run_command(
        [str(config.reference), "--cases-root", str(config.cases_root)],
        PROJECT_ROOT,
        config.timeout_seconds,
    )
    _relay_stderr(generation_result)
    if generation_result.returncode != 0:
        raise typer.Exit(code=1)

    try:
        cases = parse_manifest(config.cases_root)
        _validate_results_root(config.results_root)
    except MatrixInputError as error:
        typer.echo(str(error), err=True)
        raise typer.Exit(code=2) from error

    passed = 0
    for case in cases:
        simulator_result = run_command(
            [str(config.matrix_simulator)],
            case.directory,
            config.timeout_seconds,
        )
        result_path = config.results_root / case.identifier / "bluesim_output.txt"
        _ = result_path.parent.mkdir(parents=True, exist_ok=True)
        _ = result_path.write_text(simulator_result.stdout, encoding="utf-8")
        _relay_stderr(simulator_result)
        verifier_result = _run_verifier(config, case.expected_path, result_path)
        case_passed = (
            simulator_result.returncode == 0
            and LOADER_ERROR_MARKER not in simulator_result.stdout
            and LOADER_ERROR_MARKER not in simulator_result.stderr
            and verifier_result.returncode == 0
        )
        if case_passed:
            passed += 1
        typer.echo(f"{case.identifier} {'PASS' if case_passed else 'FAIL'}")

    if passed == len(CASE_IDS):
        typer.echo(f"MATRIX PASS {passed}/{len(CASE_IDS)}")
        return
    typer.echo(f"MATRIX FAIL {passed}/{len(CASE_IDS)}")
    raise typer.Exit(code=1)


def main() -> None:
    """Parse the strict runner CLI and execute its baseline-first matrix flow."""
    try:
        run_matrix(_parse_cli(sys.argv[1:]))
    except typer.Exit as error:
        raise SystemExit(error.exit_code) from error


if __name__ == "__main__":
    main()
