#!/usr/bin/env python3
"""Check the complete scalar simulator transcript against exported INT8 fixtures."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


def read_hex(path: Path) -> list[int]:
    values = []
    for line in path.read_text().splitlines():
        word = line.strip()
        if not re.fullmatch(r"[0-9a-fA-F]{2}", word):
            raise ValueError(f"Invalid INT8 fixture word in {path}: {word!r}")
        value = int(word, 16)
        values.append(value - 256 if value >= 128 else value)
    return values


def check_log(log_path: Path, input_path: Path, expected_path: Path,
              backend: str, stderr_path: Path | None = None) -> dict:
    evidence = {
        "bluesim": "BSV Bluesim simulation",
        "iverilog": "generated-Verilog simulation",
        "verilator": "generated-Verilog simulation (Verilator)",
    }
    if backend not in evidence:
        raise ValueError(f"Unsupported simulation backend: {backend}")
    inputs = read_hex(input_path)
    expected = read_hex(expected_path)
    if not inputs or len(inputs) % 320:
        raise ValueError("Fixture must contain complete 320-word frames")
    frames = len(inputs) // 320
    if len(expected) != frames * 57:
        raise ValueError("Fixture must contain 57 expected coordinates per frame")

    log_text = log_path.read_text(errors="replace")
    error_text = stderr_path.read_text(errors="replace") if stderr_path else ""
    if re.search(r"SWAY_FAIL|FATAL:|Error:", log_text + "\n" + error_text):
        raise AssertionError("Simulator reported a failure; inspect the simulation log")

    outputs = []
    input_events = []
    frame_events = []
    stall_events = []
    completions = []
    for line in log_text.splitlines():
        if line.startswith("SWAY_PASS "):
            match = re.fullmatch(r"SWAY_PASS frames=(\d+) outputs=(\d+) cycles=(\d+) drain_cycles=(\d+)", line)
            if not match:
                raise AssertionError("Malformed completion record")
            completions.append(tuple(int(value) for value in match.groups()))
        elif line.startswith("SWAY_"):
            fields = line.split(",")
            if fields[0] not in {"SWAY_OUTPUT", "SWAY_INPUT_FRAME", "SWAY_FRAME", "SWAY_STALL"}:
                raise AssertionError(f"Unknown simulation record: {line}")
            if len(fields) != 4:
                raise AssertionError(f"Malformed simulation record: {line}")
            record = tuple(int(value) for value in fields[1:])
            if fields[0] == "SWAY_OUTPUT":
                outputs.append(record)
            elif fields[0] == "SWAY_INPUT_FRAME":
                input_events.append(record)
            elif fields[0] == "SWAY_FRAME":
                frame_events.append(record)
            else:
                stall_events.append(record)

    if len(completions) != 1:
        raise AssertionError("Expected exactly one complete SWAY_PASS record")
    passed_frames, passed_outputs, finish_cycle, drain_cycles = completions[0]
    if passed_frames != frames or passed_outputs != len(expected):
        raise AssertionError("Completion count does not match the fixtures")
    if len(outputs) != len(expected):
        raise AssertionError("Missing or extra scalar output records")
    previous_cycle = -1
    for index, (actual_index, actual, cycle) in enumerate(outputs):
        if actual_index != index:
            raise AssertionError(f"Duplicate, missing, or reordered scalar at index {index}")
        if actual != expected[index]:
            raise AssertionError(f"Mismatch at scalar {index}: {actual} != {expected[index]}")
        if cycle <= previous_cycle:
            raise AssertionError("Scalar output cycles must strictly increase")
        previous_cycle = cycle
    if drain_cycles < 2048 or finish_cycle - outputs[-1][2] < drain_cycles:
        raise AssertionError("Incomplete post-completion extra-output drain")

    for name, events in (("input", input_events), ("frame", frame_events), ("stall", stall_events)):
        if len(events) != frames or [event[0] for event in events] != list(range(frames)):
            raise AssertionError(f"Missing, duplicate, or reordered {name} frame events")

    frame_results = []
    for frame in range(frames):
        _, input_start, input_end = input_events[frame]
        _, output_start, output_end = frame_events[frame]
        _, stall_start, stall_end = stall_events[frame]
        scalars = outputs[frame * 57:(frame + 1) * 57]
        if input_start < 0 or input_end < input_start + 319:
            raise AssertionError(f"Invalid input-frame timing at frame {frame}")
        if frame and input_start <= input_events[frame - 1][2]:
            raise AssertionError("Input-frame timings overlap")
        if output_start != scalars[0][2] or output_end != scalars[-1][2]:
            raise AssertionError(f"Output-frame timing disagrees with scalars at frame {frame}")
        if output_start <= input_end:
            raise AssertionError(f"Frame {frame} produced a full-frame prediction before input completion")
        if stall_start != output_start + 1 or stall_end - stall_start != 8192:
            raise AssertionError(f"Missing 8192-cycle sink pause at frame {frame}")
        if scalars[1][2] < stall_end:
            raise AssertionError(f"Sink consumed output during its pause at frame {frame}")
        frame_results.append({
            "frame": frame,
            "input_first_cycle": input_start,
            "input_last_cycle": input_end,
            "output_first_cycle": output_start,
            "output_last_cycle": output_end,
            "first_input_to_last_output_cycles": output_end - input_start,
            "sink_pause_cycles": stall_end - stall_start,
        })

    # Repeated input fixtures after different preceding frames test per-frame state reset.
    repeated_pairs = []
    for frame in range(1, frames):
        for previous in range(frame):
            if inputs[frame * 320:(frame + 1) * 320] == inputs[previous * 320:(previous + 1) * 320]:
                if expected[frame * 57:(frame + 1) * 57] != expected[previous * 57:(previous + 1) * 57]:
                    raise AssertionError("Repeated inputs have inconsistent reference outputs")
                repeated_pairs.append([previous, frame])
                break
    if not repeated_pairs:
        raise AssertionError("Missing repeated-frame fixture for per-frame reset coverage")

    return {
        "status": "pass",
        "evidence": evidence[backend],
        "frames_checked": frames,
        "scalar_outputs_checked": len(expected),
        "input_words": len(inputs),
        "finish_cycle": finish_cycle,
        "post_completion_drain_cycles": drain_cycles,
        "source_bubbles": "cycles modulo 17 equal to 0 or 1",
        "sink_stalls": "8192 cycles after each first output, plus cycles modulo 11 equal to 0",
        "repeated_frame_pairs_checked": repeated_pairs,
        "timing_scope": "testbench cycles include deliberate source and sink stalls; not unstalled kernel performance",
        "input_sha256": hashlib.sha256(input_path.read_bytes()).hexdigest(),
        "expected_sha256": hashlib.sha256(expected_path.read_bytes()).hexdigest(),
        "log_sha256": hashlib.sha256(log_path.read_bytes()).hexdigest(),
        "sway_records_sha256": hashlib.sha256("".join(
            line + "\n" for line in log_text.splitlines() if line.startswith("SWAY_")
        ).encode()).hexdigest(),
        "frames": frame_results,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, nargs="?")
    parser.add_argument("--log", type=Path, dest="log_option")
    parser.add_argument("--input", type=Path, default=Path("generated/test_input.hex"))
    parser.add_argument("--expected", type=Path, default=Path("generated/test_expected.hex"))
    parser.add_argument("--output", type=Path, default=Path("results/simulation.json"))
    parser.add_argument("--backend", choices=["bluesim", "iverilog", "verilator"], default="bluesim")
    parser.add_argument("--stderr", type=Path)
    args = parser.parse_args()
    if (args.log is None) == (args.log_option is None):
        parser.error("provide one log path, either positional or --log")
    log_path = args.log if args.log is not None else args.log_option
    args.output.unlink(missing_ok=True)
    result = check_log(log_path, args.input, args.expected, args.backend, args.stderr)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"SWAY_CHECK_PASS frames={result['frames_checked']} outputs={result['scalar_outputs_checked']}")


if __name__ == "__main__":
    main()
