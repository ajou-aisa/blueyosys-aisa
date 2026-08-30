"""Regression tests for CPU-to-Bluesim verification."""

from pathlib import Path

import pytest
import typer

from scripts.verify import (
    Outputs,
    OutputShapeError,
    VerificationFormatError,
    compare_outputs,
    main,
    parse_actual,
    parse_expected,
)


def test_parse_outputs_when_files_are_well_formed(tmp_path: Path) -> None:
    """Parse matching floating-point and Q16.16 values."""
    # Given
    expected_path = tmp_path / "expected.txt"
    _ = expected_path.write_text(
        "".join(
            (
                "tensor new_state\nshape 2\ndata\n",
                "0 0.5 0x3f000000\n1 -0.25 0xbe800000\nend\n",
                "tensor y\nshape 1\ndata\n0 0.125 0x3e000000\nend\n",
            ),
        ),
        encoding="utf-8",
    )
    actual_path = tmp_path / "actual.txt"
    _ = actual_path.write_text(
        "calculated_new_state_q16 32768 -16384\ncalculated_y_q16 8192\nPASS\n",
        encoding="utf-8",
    )

    # When
    expected = parse_expected(expected_path)
    actual = parse_actual(actual_path)

    # Then
    assert expected == actual == Outputs(new_state=(0.5, -0.25), y=(0.125,))


def test_compare_outputs_when_error_exceeds_tolerance() -> None:
    """Fail an element whose absolute and relative errors exceed tolerance."""
    # Given
    expected = Outputs(new_state=(1.0,), y=(1.0,))
    actual = Outputs(new_state=(1.0,), y=(2.0,))

    # When
    results = compare_outputs(expected, actual)

    # Then
    assert [result.passed for result in results] == [True, False]


@pytest.mark.parametrize("missing_name", ["expected.txt", "actual.txt"])
def test_main_reports_missing_boundary_file(
    tmp_path: Path,
    missing_name: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Report a missing expected or actual input as a verifier failure."""
    expected_path = tmp_path / "expected.txt"
    actual_path = tmp_path / "actual.txt"
    if missing_name != expected_path.name:
        _ = expected_path.write_text(
            "tensor new_state\ndata\n0 0 0x0\nend\ntensor y\ndata\n0 0 0x0\nend\n",
            encoding="utf-8",
        )
    if missing_name != actual_path.name:
        _ = actual_path.write_text(
            "calculated_new_state_q16 0\ncalculated_y_q16 0\n",
            encoding="utf-8",
        )

    with pytest.raises(typer.Exit) as raised:
        main(expected_path, actual_path)

    assert raised.value.exit_code == 2
    output = capsys.readouterr().out
    assert "FUNCTIONALITY TEST: FAIL" in output
    assert missing_name in output


def test_parse_actual_rejects_malformed_q16(tmp_path: Path) -> None:
    """Reject non-integer Q16.16 output values."""
    actual_path = tmp_path / "actual.txt"
    _ = actual_path.write_text(
        "calculated_new_state_q16 nope\ncalculated_y_q16 0\n",
        encoding="utf-8",
    )

    with pytest.raises(VerificationFormatError, match=r"invalid Q16\.16 integer"):
        _ = parse_actual(actual_path)


def test_parse_actual_rejects_missing_tensor_label(tmp_path: Path) -> None:
    """Reject output that omits a required tensor label."""
    actual_path = tmp_path / "actual.txt"
    _ = actual_path.write_text("calculated_new_state_q16 0\n", encoding="utf-8")

    with pytest.raises(
        VerificationFormatError, match="missing calculated new_state or y"
    ):
        _ = parse_actual(actual_path)


def test_compare_outputs_rejects_element_count_mismatch() -> None:
    """Reject tensors with unequal expected and actual element counts."""
    expected = Outputs(new_state=(0.0, 0.0), y=(0.0,))
    actual = Outputs(new_state=(0.0,), y=(0.0,))

    with pytest.raises(OutputShapeError, match="state: expected 2 elements, found 1"):
        _ = compare_outputs(expected, actual)
