from __future__ import annotations

from fractions import Fraction
from importlib import import_module
from pathlib import Path
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
EMAMBA = ROOT.parents[2] / "eMamba"
ARTIFACT = (EMAMBA / "results/"
            "emamba_v2_100ep_seed0_mps_20260926_ptq_validation/quantized.pt")
TABLES = ROOT / "generated/nonlinear_tables.npy"
FRACTION_BITS = 24


def saturate(value: np.ndarray, bits: int = 8) -> np.ndarray:
    return np.clip(value, -(1 << (bits - 1)), (1 << (bits - 1)) - 1).astype(np.int64)


def divide_even(numerator: np.ndarray, denominator: int | np.ndarray) -> np.ndarray:
    """Round signed integer ratios to nearest, ties to even."""
    numerator = np.asarray(numerator, dtype=np.int64)
    denominator = np.asarray(denominator, dtype=np.int64)
    quotient = numerator // denominator
    remainder = numerator - quotient * denominator
    twice = 2 * remainder
    return quotient + ((twice > denominator) | ((twice == denominator) & ((quotient & 1) == 1)))


def rescale(value: np.ndarray, source: int, target: int) -> np.ndarray:
    shift = source - target
    if shift >= 0:
        return np.asarray(value, dtype=np.int64) << shift
    return divide_even(np.asarray(value, dtype=np.int64), 1 << -shift)


class IntegerModel:
    """Artifact backed reference; trace names are frozen profile boundary names."""

    def __init__(self, artifact: Path = ARTIFACT, tables: np.ndarray | None = None) -> None:
        sys.path.insert(0, str(EMAMBA))
        loaded = import_module("ptq.artifact").load_quantized(artifact)
        self.metadata = loaded.metadata
        self.profile = self.metadata["profile"]
        self.parameters = {name: tensor.numpy().astype(np.int64)
                           for name, tensor in loaded.parameters.items()}
        self.tables = (np.load(TABLES, allow_pickle=False) if tables is None else tables).astype(np.int64)
        if self.tables.shape != (4, 256):
            raise ValueError("Expected four signed INT8 nonlinear tables")
        self.epsilon_codes: list[int] = []
        for block in range(2):
            prefix = f"blocks.{block}.norm"
            eps = float(np.float32(self.metadata["norm_epsilon"][prefix]))
            units = Fraction.from_float(eps) / Fraction(2) ** self.exponent(prefix + ".input")
            self.epsilon_codes.append(max(1, round(units * (1 << FRACTION_BITS))))

    def exponent(self, name: str) -> int:
        return int(self.profile[name]["exponent"])

    def requantize(self, value: np.ndarray, source: int, target: str) -> np.ndarray:
        return saturate(rescale(value, source, self.exponent(target)))

    def linear(self, value: np.ndarray, output: str, input_name: str,
               weight_name: str, bias_name: str | None = None) -> np.ndarray:
        exponent = self.exponent(input_name) + self.exponent(weight_name)
        accumulator = value @ self.parameters[weight_name].T
        if bias_name is not None:
            common = min(exponent, self.exponent(bias_name))
            accumulator = (rescale(accumulator, exponent, common)
                           + rescale(self.parameters[bias_name], self.exponent(bias_name), common))
            exponent = common
        return self.requantize(accumulator, exponent, output)

    def normalization(self, value: np.ndarray, block: int) -> np.ndarray:
        prefix = f"blocks.{block}.norm"
        mean = divide_even(value.sum(axis=-1, keepdims=True) << FRACTION_BITS,
                           value.shape[-1])
        centered = (value << FRACTION_BITS) - mean
        span = centered.max(axis=-1, keepdims=True) - centered.min(axis=-1, keepdims=True)
        normalized = divide_even(centered << FRACTION_BITS,
                                 np.maximum(span, self.epsilon_codes[block]))
        gamma_name, beta_name = prefix + ".gamma", prefix + ".beta"
        scaled_exponent = self.exponent(gamma_name) - FRACTION_BITS
        common = min(scaled_exponent, self.exponent(beta_name))
        total = (rescale(normalized * self.parameters[gamma_name], scaled_exponent, common)
                 + rescale(self.parameters[beta_name], self.exponent(beta_name), common))
        return self.requantize(total, common, prefix + ".output")

    def block(self, value: np.ndarray, block: int,
              trace: dict[str, np.ndarray] | None = None) -> np.ndarray:
        prefix, ssm = f"blocks.{block}", f"blocks.{block}.ssm"

        def emit(name: str, codes: np.ndarray) -> np.ndarray:
            if trace is not None:
                trace[name] = codes.copy()
            return codes

        def req(codes: np.ndarray, source: str, target: str) -> np.ndarray:
            return emit(target, self.requantize(codes, self.exponent(source), target))

        residual = req(value, "patch_embedding.output" if block == 0 else "blocks.0.output",
                       prefix + ".residual")
        norm_input = req(value, "patch_embedding.output" if block == 0 else "blocks.0.output",
                         prefix + ".norm.input")
        normalized = emit(prefix + ".norm.output", self.normalization(norm_input, block))
        gate_proj = emit(prefix + ".gateProjection", self.linear(
            normalized, prefix + ".gateProjection", prefix + ".norm.output",
            prefix + ".gate_proj.weight"))
        gate = emit(prefix + ".gate", self.tables[block * 2, gate_proj + 128])
        hidden = emit(prefix + ".inputProjection", self.linear(
            normalized, prefix + ".inputProjection", prefix + ".norm.output",
            prefix + ".input_proj.weight"))
        conv_input = req(hidden, prefix + ".inputProjection", prefix + ".conv1d.input")
        padded = np.pad(conv_input, ((0, 0), (3, 0), (0, 0)))
        accumulator = np.zeros_like(conv_input)
        weights = self.parameters[prefix + ".conv.conv1d.weight"][:, 0, :]
        for tap in range(4):
            accumulator += padded[:, tap:tap + 16] * weights[:, tap]
        conv_exponent = self.exponent(prefix + ".conv1d.input") + self.exponent(prefix + ".conv1d.weight")
        bias_name = prefix + ".conv1d.bias"
        common = min(conv_exponent, self.exponent(bias_name))
        accumulator = (rescale(accumulator, conv_exponent, common)
                       + rescale(self.parameters[prefix + ".conv.conv1d.bias"], self.exponent(bias_name), common))
        conv = emit(prefix + ".conv", self.requantize(accumulator, common, prefix + ".conv"))
        x = req(conv, prefix + ".conv", ssm + ".x")
        projected = emit(ssm + ".parameters", self.linear(
            x, ssm + ".parameters", ssm + ".x", ssm + ".ssm_param_proj.weight"))
        dt_input = req(projected[:, :, :2], ssm + ".parameters", ssm + ".deltaInput")
        b = req(projected[:, :, 2:10], ssm + ".parameters", ssm + ".B")
        c = req(projected[:, :, 10:18], ssm + ".parameters", ssm + ".C")
        dt_projection = emit(ssm + ".deltaProjection", self.linear(
            dt_input, ssm + ".deltaProjection", ssm + ".deltaInput",
            ssm + ".delta_proj.weight", ssm + ".delta_proj.bias"))
        delta = req(np.maximum(dt_projection, 0), ssm + ".deltaProjection", ssm + ".delta")
        a = emit(ssm + ".A", self.parameters[ssm + ".A"])
        d = emit(ssm + ".D", self.parameters[ssm + ".D"])
        exp_input = emit(ssm + ".expInput", self.requantize(
            delta[:, :, :, None] * a, self.exponent(ssm + ".delta") + self.exponent(ssm + ".A"),
            ssm + ".expInput"))
        abar = emit(ssm + ".Abar", self.tables[block * 2 + 1, exp_input + 128])
        bbar = emit(ssm + ".Bbar", self.requantize(
            delta[:, :, :, None] * b[:, :, None, :],
            self.exponent(ssm + ".delta") + self.exponent(ssm + ".B"), ssm + ".Bbar"))
        state = np.zeros((len(value), 40, 8), dtype=np.int64)
        outputs: list[np.ndarray] = []
        currents: list[np.ndarray] = []
        retained: list[np.ndarray] = []
        current_exp = self.exponent(ssm + ".currentState")
        state_path_exp = current_exp + self.exponent(ssm + ".C")
        direct_exp = self.exponent(ssm + ".x") + self.exponent(ssm + ".D")
        common = min(state_path_exp, direct_exp)
        for token in range(16):
            drive = rescale(bbar[:, token] * x[:, token, :, None],
                            self.exponent(ssm + ".Bbar") + self.exponent(ssm + ".x"), current_exp)
            raw_current = abar[:, token] * state + drive
            current = saturate(raw_current, 24)
            currents.append(raw_current)
            state_path = (current * c[:, token, None, :]).sum(axis=-1)
            direct = x[:, token] * d
            total = rescale(state_path, state_path_exp, common) + rescale(direct, direct_exp, common)
            outputs.append(self.requantize(total, common, ssm + ".y"))
            state = saturate(current >> 7, 17)
            retained.append(state)
        y = emit(ssm + ".y", np.stack(outputs, axis=1))
        emit(ssm + ".currentState", np.stack(currents, axis=1))
        emit(ssm + ".state", np.stack(retained, axis=1))
        gated = emit(prefix + ".gated", self.requantize(
            y * gate, self.exponent(ssm + ".y") + self.exponent(prefix + ".gate"),
            prefix + ".gated"))
        output = emit(prefix + ".projection", self.linear(
            gated, prefix + ".projection", prefix + ".gated", prefix + ".output_proj.weight"))
        common = min(self.exponent(prefix + ".residual"), self.exponent(prefix + ".projection"))
        combined = (rescale(residual, self.exponent(prefix + ".residual"), common)
                    + rescale(output, self.exponent(prefix + ".projection"), common))
        return emit(prefix + ".output", self.requantize(combined, common, prefix + ".output"))

    def forward_integer(self, inputs: np.ndarray,
                        trace: dict[str, np.ndarray] | None = None) -> np.ndarray:
        inputs = np.asarray(inputs, dtype=np.int64)
        if inputs.ndim != 4 or inputs.shape[1:] != (8, 8, 5) or not np.all((-128 <= inputs) & (inputs <= 127)):
            raise ValueError("Expected signed INT8 [batch,8,8,5] input")
        if trace is not None:
            trace["input"] = inputs.copy()
        patches = inputs.reshape(-1, 4, 2, 4, 2, 5).transpose(0, 1, 3, 2, 4, 5).reshape(-1, 16, 20)
        patches = self.requantize(patches, self.exponent("input"), "patch_embedding.patches")
        if trace is not None:
            trace["patch_embedding.patches"] = patches.copy()
        value = self.linear(patches, "patch_embedding.output", "patch_embedding.patches",
                            "patch_embedding.proj.weight", "patch_embedding.proj.bias")
        if trace is not None:
            trace["patch_embedding.output"] = value.copy()
        for block in range(2):
            value = self.block(value, block, trace)
        head_input = self.requantize(value.reshape(-1, 320), self.exponent("blocks.1.output"), "head.input")
        hidden = self.linear(head_input, "head.hidden", "head.input", "head.proj.0.weight", "head.proj.0.bias")
        activation = self.requantize(np.maximum(hidden, 0), self.exponent("head.hidden"), "head.activation")
        output = self.linear(activation, "output", "head.activation", "head.proj.2.weight", "head.proj.2.bias")
        if trace is not None:
            trace.update({"head.input": head_input.copy(), "head.hidden": hidden.copy(),
                          "head.activation": activation.copy(), "output": output.copy()})
        return output
