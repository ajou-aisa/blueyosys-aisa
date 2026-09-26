#!/usr/bin/env python3
"""Integer execution contract for the fixed MARS checkpoint.

Inference uses signed integers only after host input quantization. Range
normalization uses exact rational arithmetic with one final ties-even rounding;
this intentionally differs from the existing float32 QDQ normalization. The
nonlinear ROMs enumerate the existing float32 PWL function's INT8 input domain.
No checkpoint, scale, or calibration policy is fitted by this reference.
"""

import hashlib
import json
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "model"
EXPORT = MODEL / "export"
GENERATED = ROOT / "generated"
LAYERS = [
    ("embedding", "patches", "embedding.weight", "embedding.bias"),
    ("blocks.0.in", "blocks.0.norm", "blocks.0.inWeight", None),
    ("blocks.0.xProjection", "blocks.0.x", "blocks.0.xWeight", None),
    ("blocks.0.deltaProjection", "blocks.0.deltaInput", "blocks.0.dtWeight", "blocks.0.dtBias"),
    ("blocks.0.out", "blocks.0.gated", "blocks.0.outWeight", None),
    ("blocks.1.in", "blocks.1.norm", "blocks.1.inWeight", None),
    ("blocks.1.xProjection", "blocks.1.x", "blocks.1.xWeight", None),
    ("blocks.1.deltaProjection", "blocks.1.deltaInput", "blocks.1.dtWeight", "blocks.1.dtBias"),
    ("blocks.1.out", "blocks.1.gated", "blocks.1.outWeight", None),
    ("headHidden", "headInput", "headHidden.weight", "headHidden.bias"),
    ("output", "headActivation", "headOutput.weight", "headOutput.bias"),
]


def file_hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def saturate(value, bits=8):
    return np.clip(value, -(1 << (bits - 1)), (1 << (bits - 1)) - 1).astype(np.int64)


def divide_even(numerator, denominator):
    """Signed nearest quotient; ties choose the even integer."""
    numerator = np.asarray(numerator, dtype=np.int64)
    denominator = np.asarray(denominator, dtype=np.int64)
    if np.any(denominator <= 0):
        raise ValueError("Denominators must be positive")
    absolute = np.abs(numerator)
    quotient = absolute // denominator
    remainder = absolute % denominator
    increment = (2 * remainder > denominator) | ((2 * remainder == denominator) & ((quotient & 1) != 0))
    rounded = quotient + increment
    return np.where(numerator < 0, -rounded, rounded).astype(np.int64)


def rescale(value, source, destination):
    value = np.asarray(value, dtype=np.int64)
    shift = int(source) - int(destination)
    if shift >= 0:
        if shift >= 62 or (value.size and np.max(np.abs(value)) > ((1 << 62) - 1) >> shift):
            raise OverflowError("INT64 rescale overflow")
        return value << shift
    if -shift >= 62:
        raise OverflowError("INT64 rescale width exceeded")
    return divide_even(value, 1 << -shift)


def requantize(value, source, destination):
    return saturate(rescale(value, source, destination))


def quantize_input(value, exponent):
    value = np.asarray(value, dtype=np.float32)
    if not np.all(np.isfinite(value)):
        raise ValueError("Nonfinite host input")
    return saturate(np.rint(value / np.float32(2.0 ** exponent)))


class IntegerModel:
    def __init__(self, export=EXPORT, tables=None):
        self.export = Path(export)
        self.manifest = json.loads((self.export / "manifest.json").read_text())
        self.profile = json.loads((self.export / "quantization.json").read_text())
        self.config = self.manifest["modelConfig"]
        expected = {"D": 20, "E": 2, "P": 2, "M": 2, "N": 8, "L": 16,
                    "input_height": 8, "input_width": 8, "input_channels": 5,
                    "outputs": 57, "dt_rank": 2, "conv_kernel": 4, "head_hidden": 20}
        if any(self.config.get(key) != value for key, value in expected.items()):
            raise ValueError("Export does not match the fixed baseline workload")
        if self.profile.get("modelConfig") != self.config or not self.profile.get("usePWL"):
            raise ValueError("Model and frozen PWL profile disagree")
        for name, node in self.profile["nodes"].items():
            bits = 24 if name.endswith(".currentState") else 17 if name.endswith(".state") else 8
            if node["bits"] != bits or node["scale"] != 2.0 ** node["exponent"] or node.get("zeroPoint", 0) != 0:
                raise ValueError("Expected symmetric power-of-two quantization: " + name)
        for block in range(2):
            prefix = "blocks.%d." % block
            if self.exponent(prefix + "Abar") != -7 or self.exponent(prefix + "state") != self.exponent(prefix + "currentState") + 7:
                raise ValueError("SSM state exponent relationship is incompatible with the baseline")
        self.parameters = {}
        for entry in self.manifest["tensors"]:
            binary = self.export / entry["binary"]
            if file_hash(binary) != entry["sha256"] or binary.stat().st_size != entry["bytes"]:
                raise ValueError("Export hash/length mismatch: " + str(binary))
            values = np.frombuffer(binary.read_bytes(), dtype=entry["dtype"]).astype(np.int64)
            hexadecimal = np.array([int(line, 16) for line in (self.export / entry["hex"]).read_text().splitlines()], dtype=np.int64)
            hexadecimal = np.where(hexadecimal >= 128, hexadecimal - 256, hexadecimal)
            if not np.array_equal(values, hexadecimal):
                raise ValueError("Export hex/binary mismatch: " + entry["parameterName"])
            self.parameters[entry["parameterName"]] = values.reshape(entry["shape"])
        self.tables = np.load(GENERATED / "nonlinear_tables.npy", allow_pickle=False).astype(np.int64) if tables is None else np.asarray(tables, dtype=np.int64)
        if self.tables.shape != (6, 256):
            raise ValueError("Expected six complete signed-INT8 nonlinear tables")

    def exponent(self, name):
        return int(self.profile["nodes"][name]["exponent"])

    def linear(self, value, layer):
        output, input_name, weight_name, bias_name = LAYERS[layer]
        exponent = self.exponent(input_name) + self.exponent(weight_name)
        accumulator = value @ self.parameters[weight_name].T
        if bias_name is not None:
            common = min(exponent, self.exponent(bias_name))
            accumulator = rescale(accumulator, exponent, common) + rescale(self.parameters[bias_name], self.exponent(bias_name), common)
            exponent = common
        return requantize(accumulator, exponent, self.exponent(output))

    def normalization(self, value, prefix):
        width = value.shape[-1]
        span = value.max(axis=-1, keepdims=True) - value.min(axis=-1, keepdims=True)
        denominator = np.maximum(span, 1) * width
        centered = width * value - value.sum(axis=-1, keepdims=True)
        gamma_exponent = self.exponent(prefix + ".normWeight")
        beta_exponent = self.exponent(prefix + ".normBias")
        output_exponent = self.exponent(prefix + ".norm")
        common = min(gamma_exponent, beta_exponent, output_exponent)
        numerator = (centered * self.parameters[prefix + ".normWeight"]) << (gamma_exponent - common)
        numerator += (denominator * self.parameters[prefix + ".normBias"]) << (beta_exponent - common)
        denominator = denominator << (output_exponent - common)
        return saturate(divide_even(numerator, denominator))

    def block(self, value, block, trace):
        prefix = "blocks.%d" % block
        def emit(suffix, array):
            if trace is not None:
                trace[prefix + "." + suffix] = array.copy()
            return array
        def exp(suffix):
            return self.exponent(prefix + "." + suffix)
        def req(array, source, target):
            return emit(target, requantize(array, exp(source), exp(target)))

        normalized = emit("norm", self.normalization(value, prefix))
        expanded = emit("in", self.linear(normalized, 1 + block * 4))
        conv_input = req(expanded[:, :, :40], "in", "convInput")
        gate_input = req(expanded[:, :, 40:], "in", "gateInput")
        padded = np.pad(conv_input, ((0, 0), (3, 0), (0, 0)))
        accumulator = np.zeros_like(conv_input)
        for tap in range(4):
            accumulator += padded[:, tap:tap + 16] * self.parameters[prefix + ".convWeight"][:, 0, tap]
        accumulator_exponent = exp("convInput") + exp("convWeight")
        common = min(accumulator_exponent, exp("convBias"))
        accumulator = rescale(accumulator, accumulator_exponent, common) + rescale(self.parameters[prefix + ".convBias"], exp("convBias"), common)
        convolved = emit("conv", requantize(accumulator, common, exp("conv")))
        x = emit("x", self.tables[block * 3, convolved + 128])
        gate = emit("gate", self.tables[block * 3 + 1, gate_input + 128])
        projected = emit("xProjection", self.linear(x, 2 + block * 4))
        delta_input = req(projected[:, :, :2], "xProjection", "deltaInput")
        b = req(projected[:, :, 2:10], "xProjection", "B")
        c = req(projected[:, :, 10:18], "xProjection", "C")
        delta_projection = emit("deltaProjection", self.linear(delta_input, 3 + block * 4))
        delta = req(np.maximum(delta_projection, 0), "deltaProjection", "delta")
        exp_input = emit("expInput", requantize(delta[:, :, :, None] * self.parameters[prefix + ".A"], exp("delta") + exp("A"), exp("expInput")))
        abar = emit("Abar", self.tables[block * 3 + 2, exp_input + 128])
        bbar = emit("Bbar", requantize(delta[:, :, :, None] * b[:, :, None, :], exp("delta") + exp("B"), exp("Bbar")))
        state = np.zeros((len(value), 40, 8), dtype=np.int64)
        outputs = []
        currents = []
        retained = []
        state_output_exponent = exp("currentState") + exp("C")
        direct_output_exponent = exp("x") + exp("D")
        common = min(state_output_exponent, direct_output_exponent)
        for token in range(16):
            drive = rescale(bbar[:, token] * x[:, token, :, None], exp("Bbar") + exp("x"), exp("currentState"))
            current = saturate(abar[:, token] * state + drive, 24)
            state_output = np.sum(current * c[:, token, None, :], axis=-1)
            direct_output = x[:, token] * self.parameters[prefix + ".D"]
            accumulator = rescale(state_output, state_output_exponent, common) + rescale(direct_output, direct_output_exponent, common)
            outputs.append(requantize(accumulator, common, exp("ssmY")))
            state = saturate(current >> 7, 17)
            if trace is not None:
                currents.append(current.copy())
                retained.append(state.copy())
        y = emit("ssmY", np.stack(outputs, axis=1))
        if trace is not None:
            emit("currentState", np.stack(currents, axis=1))
            emit("state", np.stack(retained, axis=1))
        gated = emit("gated", requantize(y * gate, exp("ssmY") + exp("gate"), exp("gated")))
        projected = emit("out", self.linear(gated, 4 + block * 4))
        input_exponent = self.exponent("embedding" if block == 0 else "blocks.0.residual")
        common = min(input_exponent, exp("out"))
        residual = rescale(value, input_exponent, common) + rescale(projected, exp("out"), common)
        return emit("residual", requantize(residual, common, exp("residual")))

    def forward_integer(self, inputs, trace=None):
        inputs = np.asarray(inputs, dtype=np.int64)
        if inputs.ndim != 4 or inputs.shape[1:] != (8, 8, 5) or inputs.min() < -128 or inputs.max() > 127:
            raise ValueError("Expected signed INT8 [batch,8,8,5] input")
        patches = inputs.reshape(-1, 4, 2, 4, 2, 5).transpose(0, 1, 3, 2, 4, 5).reshape(-1, 16, 20)
        patches = requantize(patches, self.exponent("input"), self.exponent("patches"))
        value = self.linear(patches, 0)
        if trace is not None:
            trace["input"], trace["patches"], trace["embedding"] = inputs.copy(), patches.copy(), value.copy()
        value = self.block(value, 0, trace)
        value = self.block(value, 1, trace)
        head_input = requantize(value.reshape(-1, 320), self.exponent("blocks.1.residual"), self.exponent("headInput"))
        head = self.linear(head_input, 9)
        activated = requantize(np.maximum(head, 0), self.exponent("headHidden"), self.exponent("headActivation"))
        output = self.linear(activated, 10)
        if trace is not None:
            trace.update(headInput=head_input.copy(), headHidden=head.copy(), headActivation=activated.copy(), output=output.copy())
        return output

    def quantize_inputs(self, inputs):
        inputs = np.asarray(inputs, dtype=np.float32)
        divisors = np.asarray(self.config.get("input_channel_divisors", [1.0] * 5), dtype=np.float32)
        if divisors.shape != (5,) or not np.all(np.isfinite(divisors)) or np.any(divisors <= 0):
            raise ValueError("Invalid fixed input-channel divisors")
        return quantize_input(inputs / divisors, self.exponent("input"))

    def forward(self, inputs, trace=None):
        return self.forward_integer(self.quantize_inputs(inputs), trace)


def metrics(prediction, labels):
    error = (np.asarray(prediction, dtype=np.float64) - np.asarray(labels, dtype=np.float64)).reshape(-1, 3, 19) * 100.0
    mae = np.mean(np.abs(error), axis=(0, 2))
    rmse = np.sqrt(np.mean(error ** 2, axis=0)).mean(axis=1)
    return {"frames": len(error), "mae_cm": float(mae.mean()), "rmse_coordinate_mean_cm": float(rmse.mean()),
            "rmse_global_cm": float(np.sqrt(np.mean(error ** 2))), "axis_mae_cm": dict(zip("xyz", mae.tolist())),
            "axis_rmse_cm": dict(zip("xyz", rmse.tolist()))}
