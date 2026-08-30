# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "typing-extensions>=4.12",
#   "typer>=0.15,<1",
# ]
# ///
# ─── How to run ───
# From /home/cplcck/mamba-ssm-bsv:
#   uv run scripts/verify.py
"""Compare llama.cpp CPU reference output with Bluesim Q16.16 output."""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Final, Literal

import typer
from typer.models import OptionInfo
from typing_extensions import override

Q16_SCALE: Final = 65536.0
ABSOLUTE_TOLERANCE: Final = 1.0e-4
RELATIVE_TOLERANCE: Final = 1.0e-3
TENSOR_HEADER_FIELD_COUNT: Final = 2
DATA_FIELD_COUNT: Final = 3
PROJECT_ROOT: Final = Path(__file__).resolve().parent.parent
EXPECTED_PATH: Final = PROJECT_ROOT / "vectors" / "expected.txt"
ACTUAL_PATH: Final = PROJECT_ROOT / "results" / "bluesim_output.txt"
TensorName = Literal["new_state", "y"]
TENSOR_NAMES: Final[tuple[TensorName, ...]] = ("new_state", "y")
ExpectedPath = Annotated[
    Path,
    OptionInfo(
        default=...,
        param_decls=("--expected",),
        help="llama.cpp CPU reference output",
    ),
]
ActualPath = Annotated[
    Path,
    OptionInfo(
        default=...,
        param_decls=("--actual",),
        help="Bluesim Q16.16 output",
    ),
]


@dataclass(frozen=True, slots=True)
class VerificationFormatError(Exception):
    """Report malformed or incomplete verification input."""

    path: Path
    detail: str

    @override
    def __str__(self) -> str:
        """Render the source path with the format problem."""
        return f"{self.path}: {self.detail}"


@dataclass(frozen=True, slots=True)
class OutputShapeError(Exception):
    """Report differing CPU and Bluesim element counts."""

    name: str
    expected_count: int
    actual_count: int

    @override
    def __str__(self) -> str:
        """Render the output name and mismatched element counts."""
        return (
            f"{self.name}: expected {self.expected_count} elements, "
            f"found {self.actual_count}"
        )


@dataclass(frozen=True, slots=True)
class Outputs:
    """Hold floating-point state and output values."""

    new_state: tuple[float, ...]
    y: tuple[float, ...]


@dataclass(frozen=True, slots=True)
class ElementResult:
    """Hold one tolerance comparison and its errors."""

    name: str
    expected: float
    actual: float
    absolute_error: float
    relative_error: float
    passed: bool


def _tensor_name(raw_name: str, path: Path) -> TensorName:
    for tensor_name in TENSOR_NAMES:
        if raw_name == tensor_name:
            return tensor_name
    raise VerificationFormatError(path, f"unsupported tensor {raw_name!r}")


def _parse_float(raw_value: str, path: Path) -> float:
    try:
        return float(raw_value)
    except ValueError as error:
        raise VerificationFormatError(path, f"invalid float {raw_value!r}") from error


def _parse_q16_values(raw_values: list[str], path: Path) -> tuple[float, ...]:
    try:
        return tuple(int(value) / Q16_SCALE for value in raw_values)
    except ValueError as error:
        raise VerificationFormatError(path, "invalid Q16.16 integer") from error


def parse_expected(path: Path) -> Outputs:
    """Parse new_state and y tensors from the CPU reference output."""
    values: dict[TensorName, list[float]] = {"new_state": [], "y": []}
    current_tensor: TensorName | None = None
    reading_data = False

    with path.open(encoding="utf-8") as source:
        for line in source:
            tokens = line.split()
            if len(tokens) == TENSOR_HEADER_FIELD_COUNT and tokens[0] == "tensor":
                current_tensor = _tensor_name(tokens[1], path)
                reading_data = False
                continue
            if tokens == ["data"]:
                reading_data = True
                continue
            if tokens == ["end"]:
                current_tensor = None
                reading_data = False
                continue
            if (
                not reading_data
                or current_tensor is None
                or len(tokens) != DATA_FIELD_COUNT
            ):
                continue

            raw_index, raw_value, _raw_bits = tokens
            try:
                _ = int(raw_index)
            except ValueError as error:
                raise VerificationFormatError(
                    path,
                    f"invalid element index {raw_index!r}",
                ) from error
            values[current_tensor].append(_parse_float(raw_value, path))

    if not values["new_state"] or not values["y"]:
        raise VerificationFormatError(path, "missing new_state or y data")
    return Outputs(
        new_state=tuple(values["new_state"]),
        y=tuple(values["y"]),
    )


def parse_actual(path: Path) -> Outputs:
    """Parse new_state and y Q16.16 values from Bluesim output."""
    new_state: tuple[float, ...] | None = None
    y: tuple[float, ...] | None = None

    with path.open(encoding="utf-8") as source:
        for line in source:
            tokens = line.split()
            if not tokens:
                continue
            label, *raw_values = tokens
            if label == "calculated_new_state_q16":
                new_state = _parse_q16_values(raw_values, path)
                continue
            if label == "calculated_y_q16":
                y = _parse_q16_values(raw_values, path)

    if new_state is None or y is None:
        raise VerificationFormatError(path, "missing calculated new_state or y")
    return Outputs(new_state=new_state, y=y)


def _compare_series(
    name: str,
    expected: tuple[float, ...],
    actual: tuple[float, ...],
) -> tuple[ElementResult, ...]:
    if len(expected) != len(actual):
        raise OutputShapeError(name, len(expected), len(actual))

    results: list[ElementResult] = []
    for index, (expected_value, actual_value) in enumerate(
        zip(expected, actual, strict=True),
    ):
        absolute_error = abs(actual_value - expected_value)
        if expected_value != 0.0:
            relative_error = absolute_error / abs(expected_value)
        else:
            relative_error = math.inf if absolute_error != 0.0 else 0.0
        passed = absolute_error <= (
            ABSOLUTE_TOLERANCE + RELATIVE_TOLERANCE * abs(expected_value)
        )
        results.append(
            ElementResult(
                name=f"{name}[{index}]",
                expected=expected_value,
                actual=actual_value,
                absolute_error=absolute_error,
                relative_error=relative_error,
                passed=passed,
            ),
        )
    return tuple(results)


def compare_outputs(expected: Outputs, actual: Outputs) -> tuple[ElementResult, ...]:
    """Compare every new_state and y element against explicit tolerances."""
    return (
        *_compare_series("state", expected.new_state, actual.new_state),
        *_compare_series("y", expected.y, actual.y),
    )


def _print_report(results: tuple[ElementResult, ...]) -> bool:
    typer.echo(f"absolute tolerance: {ABSOLUTE_TOLERANCE:.1e}")
    typer.echo(f"relative tolerance: {RELATIVE_TOLERANCE:.1e}")
    typer.echo("pass rule: abs_error <= abs_tol + rel_tol * abs(expected)")
    typer.echo()

    for result in results:
        status = "PASS" if result.passed else "FAIL"
        message = (
            f"{result.name} {status} "
            f"expected={result.expected:.9g} actual={result.actual:.9g} "
            f"absolute_error={result.absolute_error:.3e} "
            f"relative_error={result.relative_error:.3e}"
        )
        typer.echo(message)

    y_passed = all(result.passed for result in results if result.name.startswith("y["))
    typer.echo(f"y {'PASS' if y_passed else 'FAIL'}")
    return all(result.passed for result in results)


def main(
    expected_path: ExpectedPath = EXPECTED_PATH,
    actual_path: ActualPath = ACTUAL_PATH,
) -> None:
    """Run verification and exit nonzero when parsing or comparison fails."""
    try:
        expected = parse_expected(expected_path)
        actual = parse_actual(actual_path)
        passed = _print_report(compare_outputs(expected, actual))
    except (VerificationFormatError, OutputShapeError, OSError) as error:
        typer.echo(f"FUNCTIONALITY TEST: FAIL ({error})")
        raise typer.Exit(code=2) from error

    typer.echo()
    typer.echo(f"FUNCTIONALITY TEST: {'PASS' if passed else 'FAIL'}")
    if not passed:
        raise typer.Exit(code=1)


if __name__ == "__main__":
    typer.run(main)
