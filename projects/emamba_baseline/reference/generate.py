#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["torch", "numpy", "brevitas"]
# ///
# How to run: cd projects/emamba_baseline && ../../../eMamba/.venv-ptq/bin/python reference/generate.py
"""Export the pinned eMamba PTQ artifact to combinational BSV ROMs and golden codes."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
EMAMBA = ROOT.parents[2] / "eMamba"
ARTIFACT = EMAMBA / "results/emamba_v2_100ep_seed0_mps_20260926_ptq_validation/quantized.pt"
GENERATED = ROOT / "generated"
ARTIFACT_SHA256 = "a724dec5ed6ac270ae9e4137fbfa957e7ccea15bd25021ee931bb0d8df7dd5df"
SOURCE_SHA256 = "33e3a2e51a2924b35e39afdcb3a113133852ad7243f91ba6a34f8a4a3749c1aa"
EMAMBA_COMMIT = "7c953adef12d7fd277eb31bd1d641b690171ec34"

LAYERS = (
    ("patch_embedding.output", "patch_embedding.patches", "patch_embedding.proj.weight", "patch_embedding.proj.bias"),
    ("blocks.0.inputProjection", "blocks.0.norm.output", "blocks.0.input_proj.weight", None),
    ("blocks.0.ssm.parameters", "blocks.0.ssm.x", "blocks.0.ssm.ssm_param_proj.weight", None),
    ("blocks.0.ssm.deltaProjection", "blocks.0.ssm.deltaInput", "blocks.0.ssm.delta_proj.weight", "blocks.0.ssm.delta_proj.bias"),
    ("blocks.0.projection", "blocks.0.gated", "blocks.0.output_proj.weight", None),
    ("blocks.1.inputProjection", "blocks.1.norm.output", "blocks.1.input_proj.weight", None),
    ("blocks.1.ssm.parameters", "blocks.1.ssm.x", "blocks.1.ssm.ssm_param_proj.weight", None),
    ("blocks.1.ssm.deltaProjection", "blocks.1.ssm.deltaInput", "blocks.1.ssm.delta_proj.weight", "blocks.1.ssm.delta_proj.bias"),
    ("blocks.1.projection", "blocks.1.gated", "blocks.1.output_proj.weight", None),
    ("head.hidden", "head.input", "head.proj.0.weight", "head.proj.0.bias"),
    ("output", "head.activation", "head.proj.2.weight", "head.proj.2.bias"),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rom(name: str, signature: str, choices: list[tuple[str, str, np.ndarray]], width: int) -> list[str]:
    lines = [f"function Int#(8) {name}({signature});", "    Int#(8) result = 0;"]
    for condition, address, values in choices:
        lines.extend((f"    if ({condition}) begin", f"        case ({address})"))
        for index, value in enumerate(values.reshape(-1)):
            lines.append(f"            {width}'d{index}: result = {int(value)};")
        lines.extend(("            default: result = 0;", "        endcase", "    end"))
    return lines + ["    return result;", "endfunction", ""]


def integer_function(name: str, signature: str, selector: str, choices: list[tuple[str, int]]) -> list[str]:
    lines = [f"function Integer {name}({signature});", "    Integer result = 0;"]
    for condition, value in choices:
        lines.append(f"    if ({selector} == {condition}) result = {value};")
    return lines + ["    return result;", "endfunction", ""]


def build_package(parameters: dict[str, np.ndarray], exponents: dict[str, int],
                  tables: np.ndarray, epsilon_codes: list[int]) -> str:
    lines = ["// Generated from the pinned eMamba PTQ artifact by reference/generate.py.",
             "package EMambaParameters;", ""]
    banks: list[tuple[str, str, np.ndarray]] = []
    biases: list[tuple[str, str, np.ndarray]] = []
    for layer, (_, _, weight_name, bias_name) in enumerate(LAYERS):
        weights = parameters[weight_name]
        if layer in (1, 5):
            prefix = f"blocks.{0 if layer == 1 else 1}"
            weights = np.concatenate((weights, parameters[f"{prefix}.gate_proj.weight"]), axis=0)
        assert weights.shape[0] <= 512 and weights.size <= 8192
        banks.append((f"layerId == {layer} && lane == 0", "addr", weights))
        if bias_name is not None:
            biases.append((f"layerId == {layer}", "row", parameters[bias_name]))
    lines += rom("linearWeight", "Integer layerId, Integer lane, Bit#(13) addr", banks, 13)
    lines += rom("linearBias", "Integer layerId, Bit#(9) row", biases, 9)
    for name, index in (("layerInputScale", 1), ("layerWeightScale", 2), ("layerOutputScale", 0)):
        choices = []
        for layer, entry in enumerate(LAYERS):
            key = entry[index]
            if key is None:
                raise RuntimeError("Missing required linear scale")
            choices.append((str(layer), exponents[key]))
        lines += integer_function(name, "Integer layerId", "layerId", choices)
    for name, suffix in (("layerGateWeightScale", "gate_proj.weight"),
                         ("layerGateOutputScale", "gateProjection")):
        lines += integer_function(name, "Integer layerId", "layerId", [
            (str(layer), exponents[f"blocks.{block}.{suffix}"]) for block, layer in ((0, 1), (1, 5))])
    lines += integer_function("layerBiasScale", "Integer layerId", "layerId", [
        (str(layer), exponents[bias]) for layer, entry in enumerate(LAYERS)
        if (bias := entry[3]) is not None])
    lines += ["function Bool layerHasBias(Integer layerId);", "    Bool result = False;"]
    for layer, entry in enumerate(LAYERS):
        if entry[3] is not None:
            lines.append(f"    if (layerId == {layer}) result = True;")
    lines += ["    return result;", "endfunction", ""]
    lines += integer_function("nodeScale", "String name", "name", [
        (json.dumps(name), exponent) for name, exponent in exponents.items()])
    lines += integer_function("normEpsilonCode", "Integer blockId", "blockId", [
        (str(block), value) for block, value in enumerate(epsilon_codes)])
    lines += ["function Integer blockScale(Integer blockId, String suffix);", "    Integer result = 0;"]
    aliases = {"normWeight": "norm.gamma", "normBias": "norm.beta", "norm": "norm.output",
               "normInput": "norm.input", "in": "inputProjection", "gateInput": "gateProjection",
               "convInput": "conv1d.input", "convWeight": "conv1d.weight", "convBias": "conv1d.bias",
               "conv": "conv", "gate": "gate", "gated": "gated",
               "x": "ssm.x", "xProjection": "ssm.parameters", "deltaInput": "ssm.deltaInput",
               "deltaProjection": "ssm.deltaProjection", "delta": "ssm.delta", "A": "ssm.A",
               "Abar": "ssm.Abar", "B": "ssm.B", "Bbar": "ssm.Bbar", "C": "ssm.C",
               "D": "ssm.D", "expInput": "ssm.expInput", "state": "ssm.state",
               "currentState": "ssm.currentState", "ssmY": "ssm.y", "out": "projection",
               "residualInput": "residual", "residual": "output"}
    for block in range(2):
        prefix = f"blocks.{block}."
        lines.append(f"    if (blockId == {block}) begin")
        for alias, suffix in aliases.items():
            lines.append(f"        if (suffix == {json.dumps(alias)}) result = {exponents[prefix + suffix]};")
        lines.append("    end")
    lines += ["    return result;", "endfunction", ""]
    for function, suffix in (("normWeight", "norm.gamma"), ("normBias", "norm.beta"),
                             ("convBias", "conv.conv1d.bias"), ("directD", "ssm.D")):
        lines += rom(function, "Integer blockId, Bit#(6) channel", [
            (f"blockId == {block}", "channel", parameters[f"blocks.{block}.{suffix}"])
            for block in range(2)], 6)
    lines += rom("convWeight", "Integer blockId, Integer tap, Bit#(6) channel", [
        (f"blockId == {block} && tap == {tap}", "channel",
         parameters[f"blocks.{block}.conv.conv1d.weight"][:, 0, tap])
        for block in range(2) for tap in range(4)], 6)
    lines += rom("stateA", "Integer blockId, Integer n, Bit#(6) channel", [
        (f"blockId == {block} && n == {state}", "channel",
         parameters[f"blocks.{block}.ssm.A"][:, state])
        for block in range(2) for state in range(8)], 6)
    lines += rom("nonlinearLookup", "Integer tableId, Int#(8) inputValue", [
        (f"tableId == {index}", "pack(inputValue)", np.roll(table, 128))
        for index, table in enumerate(tables)], 8)
    return "\n".join(lines + ["endpackage", ""])


def main() -> None:
    commit = subprocess.check_output(["git", "-C", str(EMAMBA), "rev-parse", "HEAD"], text=True).strip()
    if commit != EMAMBA_COMMIT:
        raise RuntimeError("eMamba source commit mismatch")
    if sha256(ARTIFACT) != ARTIFACT_SHA256:
        raise RuntimeError("Pinned PTQ artifact SHA256 mismatch")
    sys.path.insert(0, str(EMAMBA))
    from models.piecewise import PIECEWISE_SPEC, piecewise_exp, piecewise_silu
    from ptq.artifact import load_quantized
    from ptq.calibrate import profile_hash
    from ptq.ops import dequantize_codes, quantize_codes

    loaded = load_quantized(ARTIFACT)
    profile, metadata = loaded.profile, loaded.metadata
    validation = json.loads((ARTIFACT.parent / "metrics.json").read_text())
    if (validation["artifact"]["sha256"] != ARTIFACT_SHA256
            or validation["selection"]["selected"] != "percentile"
            or validation["reload"]["profile_hash"] != profile_hash(profile)):
        raise RuntimeError("Frozen validation selection or profile mismatch")
    expected_config = {"d_model": 20, "expand": 2, "patch_size": 2, "num_blocks": 2,
                       "d_state": 8, "out_dim": 57, "in_channels": 5, "readout": "flatten"}
    if metadata["model_config"] != expected_config or metadata["provenance"]["source_sha256"] != SOURCE_SHA256:
        raise RuntimeError("Pinned model configuration or checkpoint provenance mismatch")
    if metadata["quantization"].get("nonlinear") != "piecewise_fp32" or metadata["quantization"].get("piecewise") != PIECEWISE_SPEC:
        raise RuntimeError("Pinned piecewise numeric definition mismatch")
    if metadata["state"] != {"current_bits": 24, "stored_bits": 17, "right_shift": 7,
                             "output_uses_current": True}:
        raise RuntimeError("Pinned state policy mismatch")
    parameters = {name: tensor.numpy() for name, tensor in loaded.parameters.items()}
    exponents = {name: entry.exponent for name, entry in profile.entries.items()}
    branch_scales = []
    for block in range(2):
        prefix = f"blocks.{block}."
        if (exponents[prefix + "ssm.Abar"] != -7 or
                exponents[prefix + "ssm.currentState"] + 7 != exponents[prefix + "ssm.state"]):
            raise RuntimeError("Sway state exponent relationship does not hold")
        branch_scales.append({"block": block, "commonInput": exponents[prefix + "norm.output"],
                              "inputWeight": exponents[prefix + "input_proj.weight"],
                              "gateWeight": exponents[prefix + "gate_proj.weight"],
                              "inputOutput": exponents[prefix + "inputProjection"],
                              "gateOutput": exponents[prefix + "gateProjection"]})
    width_checks = [("linear MAC", 320 * 128 * 128, 32), ("depthwise convolution", 4 * 128 * 128, 18),
                    ("RangeNorm shifted numerator", 255 << 48, 64),
                    ("scan state reduction", 8 * (1 << 23) * 128, 35)]
    if any(bound >= 1 << (bits - 1) for _, bound, bits in width_checks):
        raise RuntimeError("Sway datapath width bound exceeded")
    tables = []
    table_metadata = []
    for block in range(2):
        for source, target, operation in (("gateProjection", "gate", "silu"),
                                          ("ssm.expInput", "ssm.Abar", "exp")):
            input_name, output_name = f"blocks.{block}.{source}", f"blocks.{block}.{target}"
            codes = torch.arange(-128, 128, dtype=torch.int64)
            values = dequantize_codes(codes, exponents[input_name])
            mapped = piecewise_silu(values) if operation == "silu" else piecewise_exp(values)
            table = quantize_codes(mapped, exponents[output_name]).to(torch.int8).numpy()
            tables.append(table)
            table_metadata.append({"input": input_name, "output": output_name, "operation": operation})
    tables_array = np.stack(tables)
    assert tables_array.shape == (4, 256)
    GENERATED.mkdir(parents=True, exist_ok=True)
    np.save(GENERATED / "nonlinear_tables.npy", tables_array, allow_pickle=False)
    epsilon_codes = [int(block.norm.epsilon_code) for block in loaded.model.blocks]
    (GENERATED / "EMambaParameters.bsv").write_text(
        build_package(parameters, exponents, tables_array, epsilon_codes))
    real_path = EMAMBA / "third_party/MARS/feature/featuremap_test.npy"
    real_hash = sha256(real_path)
    expected_real_hash = json.loads(metadata["provenance"]["dataset_hashes"])["test.featuremap"]
    if real_hash != expected_real_hash:
        raise RuntimeError("Real fixture data differs from artifact provenance")
    real = np.load(real_path, allow_pickle=False)
    real_indices = (0, 1, 2)
    real_codes = quantize_codes(torch.from_numpy(real[list(real_indices)].copy()), exponents["input"]).to(torch.int8).numpy()
    inputs = np.stack((np.zeros((8, 8, 5), dtype=np.int8),
                       np.full((8, 8, 5), -128, dtype=np.int8),
                       np.full((8, 8, 5), 127, dtype=np.int8),
                       np.where(np.arange(320).reshape(8, 8, 5) % 2, 127, -128).astype(np.int8)))
    inputs = np.concatenate((real_codes, inputs, real_codes[:1]), axis=0)
    loaded.model.eval()
    with torch.no_grad():
        source = dequantize_codes(torch.from_numpy(inputs.astype(np.int64)), exponents["input"])
        output = loaded.model(source)
        expected = quantize_codes(output, exponents["output"]).to(torch.int8).numpy()
    from integer_model import IntegerModel
    integer_model = IntegerModel(ARTIFACT, tables_array)
    independent = integer_model.forward_integer(inputs)
    if not np.array_equal(expected, independent):
        difference = independent.astype(np.int16) - expected.astype(np.int16)
        raise RuntimeError(f"Integer reference differs from frozen PTQ: max LSB {np.abs(difference).max()}")
    if not np.array_equal(expected[0], expected[-1]):
        raise RuntimeError("PTQ frame reset is not deterministic")
    (GENERATED / "test_input.hex").write_text("".join(f"{int(value) & 255:02x}\n" for value in inputs.flat))
    (GENERATED / "test_expected.hex").write_text("".join(f"{int(value) & 255:02x}\n" for value in expected.flat))
    (GENERATED / "GeneratedTestConfig.bsv").write_text(
        f"package GeneratedTestConfig;\n\ntypedef {len(inputs)} TestFrameCount;\n\n"
        "function String testInputPath();\n    return \"generated/test_input.hex\";\nendfunction\n\n"
        "function String testExpectedPath();\n    return \"generated/test_expected.hex\";\nendfunction\n\nendpackage\n")
    norm_inputs, norm_outputs = [], []
    with torch.no_grad():
        tokens = loaded.model.patch_embedding(source[:1])
        for block in range(2):
            input_name, output_name = f"blocks.{block}.norm.input", f"blocks.{block}.norm.output"
            real_row = quantize_codes(tokens[0, 0], exponents[input_name]).to(torch.int8).numpy()
            tie_row = np.asarray([-1, 1, 1] + [0] * 17, dtype=np.int8)
            rows = np.stack((np.zeros(20, dtype=np.int8), np.full(20, 127, dtype=np.int8),
                             (np.arange(20) % 2).astype(np.int8),
                             np.where(np.arange(20) % 2, 127, -128).astype(np.int8), tie_row, real_row))
            same_codes = dequantize_codes(torch.from_numpy(rows.astype(np.int64)), exponents[input_name])
            result = loaded.model.blocks[block].norm(same_codes)
            expected_rows = quantize_codes(result, exponents[output_name]).to(torch.int8).numpy()
            if not np.array_equal(integer_model.normalization(rows.astype(np.int64), block), expected_rows):
                raise RuntimeError(f"RangeNorm integer/PTQ mismatch in block {block}")
            norm_inputs.append(rows)
            norm_outputs.append(expected_rows)
            tokens = loaded.model.blocks[block](tokens)
    for name, data in (("norm_input.hex", norm_inputs), ("norm_expected.hex", norm_outputs)):
        (GENERATED / name).write_text("".join(f"{int(code) & 255:02x}\n" for code in np.stack(data).flat))
    from check_generated import main as check_generated
    check_generated()
    report = {"artifactSHA256": ARTIFACT_SHA256, "sourceCheckpointSHA256": SOURCE_SHA256,
              "eMambaCommit": EMAMBA_COMMIT,
              "swayHardwareCommit": "403bc7ccc0420b25d6aab3e504bfa0998d3ed39f",
              "artifactDigest": torch.load(ARTIFACT, map_location="cpu", weights_only=True)["sha256"],
              "selectedProfile": "percentile", "profileHash": profile_hash(profile),
              "modelConfig": expected_config, "quantization": metadata["quantization"],
              "profile": metadata["profile"], "normEpsilon": metadata["norm_epsilon"],
              "normEpsilonCodes": epsilon_codes,
              "branchScaleChecks": branch_scales,
              "stateRelationChecked": "Abar exponent -7; current-state exponent +7 equals stored-state exponent",
              "hardwareWidthChecks": [{"operation": name, "maximumAbsoluteValue": bound, "signedBits": bits}
                                      for name, bound, bits in width_checks],
              "parameterSHA256": {name: metadata["parameters"][name]["sha256"] for name in parameters},
              "parameterCount": sum(value.size for value in parameters.values()),
              "romVerification": {"parameterCodesMatched": 15717, "nonlinearCodesMatched": 1024,
                                  "goldenOutputCodesMatched": int(expected.size)},
              "normFixtures": {"rowsPerBlock": 6, "channelsPerRow": 20, "order": "block-major",
                               "cases": ["constant zero", "constant +127", "small span 0/1",
                                         "mixed -128/+127", "ties-to-even edge", "real test frame 0 token 0"],
                               "source": "frozen QEMamba blocks.N.norm on dequantized identical INT8 input codes",
                               "independentIntegerReferenceMatched": True},
              "linearLayers": [{"id": index, "output": entry[0], "input": entry[1], "weight": entry[2]}
                               for index, entry in enumerate(LAYERS)],
              "nonlinearTables": table_metadata, "tableAddressOrder": "signed -128..127 in .npy; two's-complement in BSV",
              "fixtures": {"count": len(inputs), "inputShape": list(inputs.shape),
                           "outputShape": list(expected.shape), "sameInputCodesAsPTQ": True,
                           "independentIntegerReferenceMatched": True,
                           "inputOrder": "8x8x5 HWC signed INT8 per frame",
                           "outputOrder": "57 signed INT8 coordinates per frame",
                           "realTestIndices": real_indices, "realDatasetSHA256": real_hash,
                           "repeatFrameMatched": True},
              "generatedSHA256": {path.name: sha256(path) for path in GENERATED.iterdir()
                                  if path.is_file() and path.name != "reference_report.json"}}
    (GENERATED / "reference_report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(f"Generated {len(parameters)} parameters ({report['parameterCount']} codes), four tables, and {len(inputs)} PTQ golden frames")


if __name__ == "__main__":
    main()
