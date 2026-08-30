from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
REFERENCE = PROJECT_ROOT / "build" / "ssm_reference"
CASE_IDS = [
    "hand_small",
    "zero",
    "positive_x",
    "negative_x",
    "random_1a2b3c4d",
    "random_31415926",
    "random_5eed1234",
    "random_c0ffee01",
    "random_deadbeef",
]
RANDOM_CASES = {
    "random_1a2b3c4d": (0x1A2B3C4D, 3.036e-5),
    "random_31415926": (0x31415926, 2.522e-5),
    "random_5eed1234": (0x5EED1234, 2.039e-5),
    "random_c0ffee01": (0xC0FFEE01, 3.061e-5),
    "random_deadbeef": (0xDEADBEEF, 2.612e-5),
}
BASELINE_HASHES = {
    "input.txt": "9ae5a1736bac853853fe2323ab5290db5e996b3a256444d615149f0146c95980",
    "expected.txt": "e7ef072ff7caeb9c84b517108abf45a36759f2e391fb997587311599b73f2f97",
}


def run_reference(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(REFERENCE), *args],
        cwd=PROJECT_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def input_words(path: Path) -> list[int]:
    return [
        int(line, 16)
        for line in path.read_text().splitlines()
        if not line.startswith("//")
    ]


def expected_values(path: Path) -> dict[str, list[float]]:
    tensors: dict[str, list[float]] = {}
    current: str | None = None
    in_data = False
    for line in path.read_text().splitlines():
        if line.startswith("tensor "):
            current = line.split()[1]
            tensors[current] = []
            in_data = False
        elif line == "data":
            in_data = True
        elif line == "end":
            in_data = False
        elif in_data and current is not None:
            tensors[current].append(float(line.split()[1]))
    return tensors


def lcg_input_words(seed: int) -> list[int]:
    words: list[int] = []
    state = seed
    for lo, hi, count in [
        (-64, 64, 4),
        (-64, 64, 2),
        (-32, 32, 2),
        (-256, -64, 4),
        (-64, 64, 2),
        (-64, 64, 2),
    ]:
        for _ in range(count):
            state = (state * 1664525 + 1013904223) & 0xFFFF_FFFF
            q = lo + ((state >> 16) % (hi - lo + 1))
            words.append((q * 256) & 0xFFFF_FFFF)
    return words


def signed_q16(word: int) -> int:
    return word if word < 0x8000_0000 else word - 0x1_0000_0000


def multiply_q16(lhs: int, rhs: int) -> int:
    return (lhs * rhs) >> 16


def softplus_q16(value: int) -> int:
    squared = multiply_q16(value, value)
    fourth = multiply_q16(squared, squared)
    sixth = multiply_q16(fourth, squared)
    return (
        45426
        + (value >> 1)
        + multiply_q16(squared, 8192)
        - multiply_q16(fourth, 341)
        + multiply_q16(sixth, 23)
    )


def exp_q16(value: int) -> int:
    squared = multiply_q16(value, value)
    cubed = multiply_q16(squared, value)
    fourth = multiply_q16(cubed, value)
    fifth = multiply_q16(fourth, value)
    sixth = multiply_q16(fifth, value)
    return (
        65536
        + value
        + multiply_q16(squared, 32768)
        + multiply_q16(cubed, 10923)
        + multiply_q16(fourth, 2731)
        + multiply_q16(fifth, 546)
        + multiply_q16(sixth, 91)
    )


def q16_outputs(words: list[int]) -> tuple[list[float], list[float]]:
    state, x, dt, a, b, c = [
        list(map(signed_q16, words[offset : offset + count]))
        for offset, count in [(0, 4), (4, 2), (6, 2), (8, 4), (12, 2), (14, 2)]
    ]
    new_state: list[float] = []
    y: list[float] = []
    for channel in range(2):
        accumulator = 0
        delta = softplus_q16(dt[channel])
        x_delta = multiply_q16(x[channel], delta)
        for state_index in range(2):
            decay = exp_q16(multiply_q16(delta, a[channel * 2 + state_index]))
            updated = multiply_q16(
                state[channel * 2 + state_index], decay
            ) + multiply_q16(b[state_index], x_delta)
            new_state.append(updated / 65536.0)
            accumulator += multiply_q16(updated, c[state_index])
        y.append(accumulator / 65536.0)
    return new_state, y


def test_cases_root_generates_catalog_with_fixed_and_seeded_vectors(
    tmp_path: Path,
) -> None:
    root = tmp_path / "cases"

    completed = run_reference("--cases-root", str(root))

    assert completed.returncode == 0, completed.stderr
    assert (root / "manifest.txt").read_text().splitlines() == [
        "format mamba_ssm_case_manifest_v1",
        *[f"case {case_id}" for case_id in CASE_IDS],
    ]
    assert sorted(
        path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file()
    ) == [
        "hand_small/expected.txt",
        "hand_small/input.txt",
        "manifest.txt",
        "negative_x/expected.txt",
        "negative_x/input.txt",
        "positive_x/expected.txt",
        "positive_x/input.txt",
        "random_1a2b3c4d/expected.txt",
        "random_1a2b3c4d/input.txt",
        "random_31415926/expected.txt",
        "random_31415926/input.txt",
        "random_5eed1234/expected.txt",
        "random_5eed1234/input.txt",
        "random_c0ffee01/expected.txt",
        "random_c0ffee01/input.txt",
        "random_deadbeef/expected.txt",
        "random_deadbeef/input.txt",
        "zero/expected.txt",
        "zero/input.txt",
    ]

    assert input_words(root / "hand_small" / "input.txt") == [
        0x00004000,
        0xFFFF8000,
        0x0000C000,
        0x00010000,
        0x00010000,
        0xFFFF0000,
        0x00000000,
        0x00000000,
        0xFFFF0000,
        0xFFFF0000,
        0xFFFF0000,
        0xFFFF0000,
        0x00000000,
        0x00000000,
        0x00010000,
        0x00000000,
    ]
    hand_small = expected_values(root / "hand_small" / "expected.txt")
    assert hand_small["new_state"] == [0.125, -0.25, 0.375, 0.5]
    assert hand_small["y"] == [0.125, 0.375]
    assert input_words(root / "zero" / "input.txt") == [0] * 16
    zero = expected_values(root / "zero" / "expected.txt")
    assert zero["new_state"] == [0.0] * 4
    assert zero["y"] == [0.0] * 2
    assert input_words(root / "positive_x" / "input.txt") == [
        0x00001000,
        0x00002000,
        0x00003000,
        0x00004000,
        0x00002000,
        0x00004000,
        0x00001000,
        0x00002000,
        0xFFFFC000,
        0xFFFF8000,
        0xFFFF4000,
        0xFFFF0000,
        0x00002000,
        0x00004000,
        0x00004000,
        0x00008000,
    ]
    assert input_words(root / "negative_x" / "input.txt") == [
        0x00001000,
        0x00002000,
        0x00003000,
        0x00004000,
        0xFFFFE000,
        0xFFFFC000,
        0x00001000,
        0x00002000,
        0xFFFFC000,
        0xFFFF8000,
        0xFFFF4000,
        0xFFFF0000,
        0x00002000,
        0x00004000,
        0x00004000,
        0x00008000,
    ]
    for case_id, (seed, max_error_bound) in RANDOM_CASES.items():
        words = input_words(root / case_id / "input.txt")
        assert words == lcg_input_words(seed)
        assert all(
            -0.25 <= signed_q16(word) / 65536.0 <= 0.25
            for word in words[0:6] + words[12:16]
        )
        assert all(-0.125 <= signed_q16(word) / 65536.0 <= 0.125 for word in words[6:8])
        assert all(-1.0 <= signed_q16(word) / 65536.0 <= -0.25 for word in words[8:12])
        expected = expected_values(root / case_id / "expected.txt")
        q16_state, q16_y = q16_outputs(words)
        max_error = max(
            *(
                abs(cpu - fixed)
                for cpu, fixed in zip(expected["new_state"], q16_state, strict=True)
            ),
            *(
                abs(cpu - fixed)
                for cpu, fixed in zip(expected["y"], q16_y, strict=True)
            ),
        )
        assert max_error <= max_error_bound + 5e-9


def test_cases_root_is_deterministic_and_rejects_bad_or_stale_roots(
    tmp_path: Path,
) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    assert run_reference("--cases-root", str(first)).returncode == 0
    assert run_reference("--cases-root", str(second)).returncode == 0

    first_files = sorted(
        path.relative_to(first) for path in first.rglob("*") if path.is_file()
    )
    second_files = sorted(
        path.relative_to(second) for path in second.rglob("*") if path.is_file()
    )
    assert first_files == second_files
    for relative_path in first_files:
        assert (
            hashlib.sha256((first / relative_path).read_bytes()).digest()
            == hashlib.sha256((second / relative_path).read_bytes()).digest()
        )

    altered_path = second / "hand_small" / "input.txt"
    original = altered_path.read_bytes()
    _ = altered_path.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
    assert (
        hashlib.sha256((first / "hand_small" / "input.txt").read_bytes()).digest()
        != hashlib.sha256(altered_path.read_bytes()).digest()
    )

    stale = tmp_path / "stale"
    (stale / "unexpected").mkdir(parents=True)
    assert run_reference("--cases-root", str(stale)).returncode != 0
    assert run_reference("--cases-root").returncode != 0
    assert (
        run_reference("--cases-root", str(tmp_path / "unused"), "extra").returncode != 0
    )
    unknown = run_reference("--unknown")
    assert unknown.returncode != 0
    assert not (PROJECT_ROOT / "--unknown").exists()
    empty = run_reference("")
    assert empty.returncode != 0
    assert "usage:" in empty.stderr


def test_legacy_cli_and_help_remain_available(tmp_path: Path) -> None:
    assert "--cases-root" in run_reference("--help").stdout
    assert run_reference().returncode == 0
    for filename, digest in BASELINE_HASHES.items():
        assert (
            hashlib.sha256(
                (PROJECT_ROOT / "vectors" / filename).read_bytes()
            ).hexdigest()
            == digest
        )
    legacy_directory = tmp_path / "legacy"
    assert run_reference(str(legacy_directory)).returncode == 0
    assert (legacy_directory / "input.txt").is_file()
    assert (legacy_directory / "expected.txt").is_file()
