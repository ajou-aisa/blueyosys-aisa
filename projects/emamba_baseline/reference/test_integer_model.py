from __future__ import annotations

import sys

import numpy as np
import torch

from integer_model import ARTIFACT, EMAMBA, IntegerModel, divide_even

sys.path.insert(0, str(EMAMBA))
from ptq.artifact import load_quantized
from ptq.ops import dequantize_codes, quantize_codes
from ptq.quant import QuantRuntime


def test_frozen_frame_boundaries(monkeypatch) -> None:
    reference = IntegerModel()
    frozen = load_quantized(ARTIFACT).model.eval()
    random = np.random.default_rng(27)
    frames = random.integers(-128, 128, (12, 8, 8, 5), dtype=np.int8)
    real = np.load(EMAMBA / "third_party/MARS/feature/featuremap_test.npy", allow_pickle=False)[:1].copy()
    real_codes = quantize_codes(torch.from_numpy(real), reference.exponent("input")).to(torch.int8).numpy()
    frames = np.concatenate((frames, real_codes))
    trace: dict[str, np.ndarray] = {}
    actual = reference.forward_integer(frames, trace)
    seen: dict[str, list[np.ndarray]] = {}
    original_boundary = QuantRuntime.boundary
    original_record = QuantRuntime.record_codes

    def boundary(self, name, value, bits=8):
        result = original_boundary(self, name, value, bits)
        if self is frozen.runtime:
            code = quantize_codes(result, reference.exponent(name), bits).numpy().copy()
            seen.setdefault(name, []).append(code)
        return result

    def record(self, name, codes, bits):
        if self is frozen.runtime and name.endswith(("currentState", "state")):
            seen.setdefault(name, []).append(codes.numpy().copy())
        return original_record(self, name, codes, bits)

    monkeypatch.setattr(QuantRuntime, "boundary", boundary)
    monkeypatch.setattr(QuantRuntime, "record_codes", record)
    exponent = reference.exponent("input")
    with torch.no_grad():
        output = frozen(dequantize_codes(torch.from_numpy(frames.astype(np.int64)), exponent))
    expected = quantize_codes(output, reference.exponent("output")).numpy()
    assert np.array_equal(actual, expected)
    assert np.any(trace["blocks.0.ssm.deltaProjection"] < 0)
    assert np.all(trace["blocks.0.ssm.delta"] >= 0)
    for name, codes in trace.items():
        frozen_codes = seen[name]
        if name.endswith(("expInput", "Abar", "Bbar", "currentState", "state")):
            comparison = np.stack(frozen_codes, axis=1)
        else:
            comparison = frozen_codes[-1]
        if name.endswith("conv1d.input"):
            comparison = comparison.transpose(0, 2, 1)
        assert np.array_equal(codes, comparison), name


def test_range_norm_edge_codes() -> None:
    reference = IntegerModel()
    frozen = load_quantized(ARTIFACT).model.eval()
    rows = np.stack((np.zeros(20), np.full(20, 127),
                     np.array([-128, 127] * 10), np.array([0] * 19 + [1])))
    codes = np.repeat(rows[:, None, :], 16, axis=1).astype(np.int64)
    for block in range(2):
        name = f"blocks.{block}.norm"
        with torch.no_grad():
            value = dequantize_codes(torch.from_numpy(codes), reference.exponent(name + ".input"))
            result = frozen.blocks[block].norm(value)
        expected = quantize_codes(result, reference.exponent(name + ".output")).numpy()
        assert np.array_equal(reference.normalization(codes, block), expected)


def test_signed_ties_round_to_even() -> None:
    numerator = np.array([-7, -5, -3, -1, 1, 3, 5, 7], dtype=np.int64)
    expected = np.array([-4, -2, -2, 0, 0, 2, 2, 4], dtype=np.int64)
    assert np.array_equal(divide_even(numerator, 2), expected)
