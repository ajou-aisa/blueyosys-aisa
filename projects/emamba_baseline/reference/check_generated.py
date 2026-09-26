#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["torch", "numpy", "brevitas"]
# ///
# How to run: cd projects/emamba_baseline && ../../../eMamba/.venv-ptq/bin/python reference/check_generated.py
"""Check all generated ROM entries and golden vectors against the pinned PTQ artifact."""

from __future__ import annotations

import re
import sys

import numpy as np
import torch

from generate import ARTIFACT, EMAMBA, GENERATED, LAYERS, sha256, ARTIFACT_SHA256


def function_text(package: str, name: str) -> str:
    match = re.search(rf"function Int#\(8\) {name}\(.*?\);(.*?)endfunction", package, re.S)
    if match is None:
        raise AssertionError(f"Missing ROM {name}")
    return match.group(1)


def bank_values(function: str, condition: str, width: int) -> np.ndarray:
    match = re.search(rf"if \({re.escape(condition)}\) begin\s+case \(.*?\)(.*?)endcase", function, re.S)
    if match is None:
        raise AssertionError(f"Missing ROM bank {condition}")
    entries = [(int(address), int(value)) for address, value in
               re.findall(rf"{width}'d(\d+): result = (-?\d+);", match.group(1))]
    if [address for address, _ in entries] != list(range(len(entries))):
        raise AssertionError(f"Noncontiguous ROM bank {condition}")
    return np.asarray([value for _, value in entries], dtype=np.int8)


def main() -> None:
    if sha256(ARTIFACT) != ARTIFACT_SHA256:
        raise AssertionError("Pinned artifact changed")
    sys.path.insert(0, str(EMAMBA))
    from models.piecewise import piecewise_exp, piecewise_silu
    from ptq.artifact import load_quantized
    from ptq.ops import dequantize_codes, quantize_codes

    artifact = load_quantized(ARTIFACT)
    parameters = {name: value.numpy() for name, value in artifact.parameters.items()}
    package = (GENERATED / "EMambaParameters.bsv").read_text()
    checked = 0
    linear = function_text(package, "linearWeight")
    bias = function_text(package, "linearBias")
    for layer, (_, _, weight_name, bias_name) in enumerate(LAYERS):
        weights = parameters[weight_name]
        if layer in (1, 5):
            block = 0 if layer == 1 else 1
            weights = np.concatenate((weights, parameters[f"blocks.{block}.gate_proj.weight"]), axis=0)
        actual = bank_values(linear, f"layerId == {layer} && lane == 0", 13)
        if not np.array_equal(actual, weights.reshape(-1)):
            raise AssertionError(f"Linear ROM mismatch at layer {layer}")
        checked += actual.size
        if bias_name is not None:
            actual = bank_values(bias, f"layerId == {layer}", 9)
            if not np.array_equal(actual, parameters[bias_name]):
                raise AssertionError(f"Bias ROM mismatch at layer {layer}")
            checked += actual.size
    for function, suffix in (("normWeight", "norm.gamma"), ("normBias", "norm.beta"),
                             ("convBias", "conv.conv1d.bias"), ("directD", "ssm.D")):
        body = function_text(package, function)
        for block in range(2):
            actual = bank_values(body, f"blockId == {block}", 6)
            expected = parameters[f"blocks.{block}.{suffix}"]
            if not np.array_equal(actual, expected):
                raise AssertionError(f"{function} ROM mismatch at block {block}")
            checked += actual.size
    for function, suffix, count in (("convWeight", "conv.conv1d.weight", 4),
                                    ("stateA", "ssm.A", 8)):
        body = function_text(package, function)
        selector = "tap" if function == "convWeight" else "n"
        for block in range(2):
            tensor = parameters[f"blocks.{block}.{suffix}"]
            for index in range(count):
                actual = bank_values(body, f"blockId == {block} && {selector} == {index}", 6)
                expected = tensor[:, 0, index] if function == "convWeight" else tensor[:, index]
                if not np.array_equal(actual, expected):
                    raise AssertionError(f"{function} ROM mismatch at block {block}, index {index}")
                checked += actual.size
    if checked != 15_717:
        raise AssertionError(f"Expected 15,717 parameter codes, checked {checked}")
    tables = np.load(GENERATED / "nonlinear_tables.npy", allow_pickle=False)
    if tables.shape != (4, 256):
        raise AssertionError("Nonlinear tables must cover four full INT8 domains")
    body = function_text(package, "nonlinearLookup")
    for index, table in enumerate(tables):
        if not np.array_equal(bank_values(body, f"tableId == {index}", 8), np.roll(table, 128)):
            raise AssertionError(f"Nonlinear ROM mismatch at table {index}")
        block, operation = divmod(index, 2)
        source = f"blocks.{block}.gateProjection" if operation == 0 else f"blocks.{block}.ssm.expInput"
        target = f"blocks.{block}.gate" if operation == 0 else f"blocks.{block}.ssm.Abar"
        codes = torch.arange(-128, 128, dtype=torch.int64)
        values = dequantize_codes(codes, artifact.profile.entries[source].exponent)
        mapped = piecewise_silu(values) if operation == 0 else piecewise_exp(values)
        canonical = quantize_codes(mapped, artifact.profile.entries[target].exponent).to(torch.int8).numpy()
        if not np.array_equal(table, canonical):
            raise AssertionError(f"Nonlinear LUT differs from canonical PTQ PWL at table {index}")
    input_codes = np.loadtxt(GENERATED / "test_input.hex", dtype=str)
    inputs = np.fromiter((int(word, 16) for word in input_codes), dtype=np.uint8).view(np.int8).reshape(-1, 8, 8, 5)
    expected = np.fromiter((int(word, 16) for word in np.loadtxt(GENERATED / "test_expected.hex", dtype=str)),
                           dtype=np.uint8).view(np.int8).reshape(-1, 57)
    artifact.model.eval()
    with torch.no_grad():
        real = dequantize_codes(torch.from_numpy(inputs.astype(np.int64)), artifact.profile.entries["input"].exponent)
        actual = quantize_codes(artifact.model(real), artifact.profile.entries["output"].exponent).to(torch.int8).numpy()
    if not np.array_equal(actual, expected):
        raise AssertionError("Golden vectors differ from frozen PTQ on same input codes")
    print(f"ROM_CHECK_PASS parameters={checked} table_codes={tables.size} frames={len(inputs)}")


if __name__ == "__main__":
    main()
