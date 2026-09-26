package SwayBlock;

import Vector::*;
import FIFO::*;

import SwayTypes::*;
import SwayParameters::*;
import SwayLinear::*;
import SwayNorm::*;
import SwayScan::*;

typedef 2 ConvLanes;
typedef TDiv#(InnerDim, ConvLanes) ConvGroups;

typedef struct {
	Bit#(5) group;
	Vector#(ConvLanes, Int#(18)) sum;
	Vector#(ConvLanes, Int#(8)) gate;
} ConvPartial deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(4) index;
	Vector#(StateDim, Int#(8)) b;
	Vector#(StateDim, Int#(8)) c;
} StateParameters deriving (Bits, Eq, FShow);

module mkSwayBlock#(Integer blockId)(BlockIfc);
	Integer firstLinear = 1 + blockId * 4;
	Integer inExp = blockScale(blockId, "in");
	Integer convInputExp = blockScale(blockId, "convInput");
	Integer gateInputExp = blockScale(blockId, "gateInput");
	Integer convProductExp = convInputExp + blockScale(blockId, "convWeight");
	Integer convBiasExp = blockScale(blockId, "convBias");
	Integer convAccumulatorExp = convProductExp < convBiasExp ? convProductExp : convBiasExp;
	Integer projectionExp = blockScale(blockId, "xProjection");
	Integer residualInputExp = blockId == 0 ? nodeScale("embedding") : blockScale(blockId - 1, "residual");
	Integer outExp = blockScale(blockId, "out");
	Integer residualAccumulatorExp = residualInputExp < outExp ? residualInputExp : outExp;

	NormIfc normalization <- mkSwayNorm(blockId);
	LinearIfc#(ModelDim, ExpandedDim) inputProjection <- mkSwayLinear(firstLinear);
	LinearIfc#(InnerDim, ProjectionDim) stateProjection <- mkSwayLinear(firstLinear + 1);
	LinearIfc#(DeltaRank, InnerDim) deltaProjection <- mkSwayLinear(firstLinear + 2);
	LinearIfc#(InnerDim, ModelDim) outputProjection <- mkSwayLinear(firstLinear + 3);
	ScanIfc scan <- mkSwayScan(blockId);

	FIFO#(Token#(ModelDim)) inputQ <- mkFIFO1;
	// Four residual slots allow tokens to occupy independent downstream engines.
	FIFO#(Token#(ModelDim)) residualQ <- mkSizedFIFO(valueOf(ResidualSlots));
	FIFO#(Token#(ModelDim)) outputQ <- mkFIFO1;
	FIFO#(Token#(ExpandedDim)) expandedQ <- mkFIFO1;
	FIFO#(ConvPartial) convolvedQ <- mkFIFO;
	FIFO#(Token#(InnerDim)) activatedQ <- mkFIFO1;
	FIFO#(Token#(InnerDim)) xDelayQ <- mkFIFO1;
	FIFO#(Token#(InnerDim)) gateDelayQ <- mkSizedFIFO(valueOf(ResidualSlots));
	FIFO#(StateParameters) stateParameterQ <- mkFIFO1;

	// Three causal samples per channel, banked across the two convolution lanes.
	Vector#(ConvHistory, Vector#(ConvLanes, Vector#(ConvGroups, Reg#(Int#(8))))) historyR <- replicateM(replicateM(replicateM(mkReg(0))));
	Reg#(Token#(ExpandedDim)) expandedR <- mkRegU;
	Reg#(Vector#(InnerDim, Int#(8))) activatedR <- mkRegU;
	Reg#(Vector#(InnerDim, Int#(8))) gateR <- mkRegU;
	Reg#(Bit#(5)) convGroupCnt <- mkReg(0);
	Reg#(Bool) convolutionOn <- mkReg(False);

	Reg#(Token#(InnerDim)) scannedR <- mkRegU;
	Reg#(Token#(InnerDim)) delayedGateR <- mkRegU;
	Reg#(Vector#(InnerDim, Int#(8))) gatedR <- mkRegU;
	Reg#(Bit#(5)) gateGroupCnt <- mkReg(0);
	Reg#(Bool) gatingOn <- mkReg(False);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Normalize and expand, preserving the original token on the residual branch.
	//------------------------------------------------------------------------------------
	rule process1;
		let value = inputQ.first;
		inputQ.deq;
		normalization.put(value);
		residualQ.enq(value);
	endrule

	rule process2;
		let value <- normalization.get;
		inputProjection.put(value);
	endrule

	rule process3;
		let value <- inputProjection.get;
		expandedQ.enq(value);
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Two depthwise channels per cycle, each using all four taps in parallel.
	// Token zero injects causal zero padding and replaces every history entry.
	//------------------------------------------------------------------------------------
	rule process4_1 ( !convolutionOn );
		expandedR <= expandedQ.first;
		expandedQ.deq;
		convGroupCnt <= 0;
		convolutionOn <= True;
	endrule

	rule process4_2 ( convolutionOn && convGroupCnt < fromInteger(valueOf(ConvGroups)) );
		ConvPartial value = unpack(0);
		value.group = convGroupCnt;
		for ( Integer lane = 0; lane < valueOf(ConvLanes); lane = lane + 1 ) begin
			Bit#(6) channel = (zeroExtend(convGroupCnt) * fromInteger(valueOf(ConvLanes))) + fromInteger(lane);
			Bit#(7) gateChannel = zeroExtend(channel) + fromInteger(valueOf(InnerDim));
			Int#(8) inputValue = requant(signExtend(expandedR.data[channel]), inExp, convInputExp);
			Vector#(ConvTaps, Int#(8)) samples = newVector;
			for ( Integer tap = 0; tap < valueOf(ConvHistory); tap = tap + 1 ) begin
				samples[tap] = expandedR.index == 0 ? 0 : historyR[tap][lane][convGroupCnt];
			end
			samples[3] = inputValue;
			Vector#(ConvTaps, Int#(16)) products = newVector;
			for ( Integer tap = 0; tap < valueOf(ConvTaps); tap = tap + 1 ) begin
				products[tap] = signExtend(samples[tap]) * signExtend(convWeight(blockId, tap, channel));
			end
			Int#(17) firstSum = signExtend(products[0]) + signExtend(products[1]);
			Int#(17) secondSum = signExtend(products[2]) + signExtend(products[3]);
			value.sum[lane] = signExtend(firstSum) + signExtend(secondSum);
			value.gate[lane] = requant(signExtend(expandedR.data[gateChannel]), inExp, gateInputExp);
			historyR[0][lane][convGroupCnt] <= samples[1];
			historyR[1][lane][convGroupCnt] <= samples[2];
			historyR[2][lane][convGroupCnt] <= samples[3];
		end
		convolvedQ.enq(value);
		convGroupCnt <= convGroupCnt + 1;
	endrule

	rule process4_3 ( convolutionOn );
		let value = convolvedQ.first;
		convolvedQ.deq;
		Vector#(InnerDim, Int#(8)) x = activatedR;
		Vector#(InnerDim, Int#(8)) gate = gateR;
		for ( Integer lane = 0; lane < valueOf(ConvLanes); lane = lane + 1 ) begin
			Bit#(6) channel = (zeroExtend(value.group) * fromInteger(valueOf(ConvLanes))) + fromInteger(lane);
			Int#(64) accumulator = shiftRound(signExtend(value.sum[lane]), convProductExp, convAccumulatorExp);
			accumulator = accumulator + shiftRound(signExtend(convBias(blockId, channel)), convBiasExp, convAccumulatorExp);
			Int#(8) convolved = requant(accumulator, convAccumulatorExp, blockScale(blockId, "conv"));
			x[channel] = nonlinearLookup(blockId * 3, convolved);
			gate[channel] = nonlinearLookup(blockId * 3 + 1, value.gate[lane]);
		end
		activatedR <= x;
		gateR <= gate;
		if ( value.group == fromInteger(valueOf(ConvGroups) - 1) ) begin
			activatedQ.enq(Token {index: expandedR.index, data: x});
			gateDelayQ.enq(Token {index: expandedR.index, data: gate});
			convolutionOn <= False;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Form delta, B and C. Each split has its own calibration exponent.
	//------------------------------------------------------------------------------------
	rule process5;
		let value = activatedQ.first;
		activatedQ.deq;
		stateProjection.put(value);
		xDelayQ.enq(value);
	endrule

	rule process6;
		let value <- stateProjection.get;
		Vector#(DeltaRank, Int#(8)) deltaInput = newVector;
		StateParameters parameters = unpack(0);
		parameters.index = value.index;
		for ( Integer lane = 0; lane < valueOf(DeltaRank); lane = lane + 1 ) begin
			deltaInput[lane] = requant(signExtend(value.data[lane]), projectionExp, blockScale(blockId, "deltaInput"));
		end
		for ( Integer lane = 0; lane < valueOf(StateDim); lane = lane + 1 ) begin
			parameters.b[lane] = requant(signExtend(value.data[valueOf(DeltaRank) + lane]), projectionExp, blockScale(blockId, "B"));
			parameters.c[lane] = requant(signExtend(value.data[valueOf(DeltaRank) + valueOf(StateDim) + lane]), projectionExp, blockScale(blockId, "C"));
		end
		deltaProjection.put(Token {index: value.index, data: deltaInput});
		stateParameterQ.enq(parameters);
	endrule

	rule process7;
		let delta <- deltaProjection.get;
		let x = xDelayQ.first;
		xDelayQ.deq;
		let parameters = stateParameterQ.first;
		stateParameterQ.deq;
		Vector#(InnerDim, Int#(8)) positiveDelta = newVector;
		for ( Integer channel = 0; channel < valueOf(InnerDim); channel = channel + 1 ) begin
			Int#(8) reluValue = delta.data[channel] < 0 ? 0 : delta.data[channel];
			positiveDelta[channel] = requant(signExtend(reluValue), blockScale(blockId, "deltaProjection"), blockScale(blockId, "delta"));
		end
		scan.put(ScanToken {index: x.index, x: x.data, delta: positiveDelta, b: parameters.b, c: parameters.c});
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 4]
	// Rejoin the aligned gate after recurrence and apply two products per cycle.
	//------------------------------------------------------------------------------------
	rule process8 ( !gatingOn );
		let value <- scan.get;
		scannedR <= value;
		delayedGateR <= gateDelayQ.first;
		gateDelayQ.deq;
		gateGroupCnt <= 0;
		gatingOn <= True;
	endrule

	rule process9 ( gatingOn );
		Vector#(InnerDim, Int#(8)) result = gatedR;
		for ( Integer lane = 0; lane < valueOf(ConvLanes); lane = lane + 1 ) begin
			Bit#(6) channel = (zeroExtend(gateGroupCnt) * fromInteger(valueOf(ConvLanes))) + fromInteger(lane);
			Int#(16) product = signExtend(scannedR.data[channel]) * signExtend(delayedGateR.data[channel]);
			result[channel] = requant(signExtend(product), blockScale(blockId, "ssmY") + blockScale(blockId, "gate"), blockScale(blockId, "gated"));
		end
		gatedR <= result;
		if ( gateGroupCnt == fromInteger(valueOf(ConvGroups) - 1) ) begin
			outputProjection.put(Token {index: scannedR.index, data: result});
			gatingOn <= False;
		end else begin
			gateGroupCnt <= gateGroupCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 5]
	// Align exponents before residual addition, then round and saturate once.
	//------------------------------------------------------------------------------------
	rule process10;
		let projected <- outputProjection.get;
		let residual = residualQ.first;
		residualQ.deq;
		Vector#(ModelDim, Int#(8)) result = newVector;
		for ( Integer channel = 0; channel < valueOf(ModelDim); channel = channel + 1 ) begin
			Int#(64) accumulator = shiftRound(signExtend(projected.data[channel]), outExp, residualAccumulatorExp);
			accumulator = accumulator + shiftRound(signExtend(residual.data[channel]), residualInputExp, residualAccumulatorExp);
			result[channel] = requant(accumulator, residualAccumulatorExp, blockScale(blockId, "residual"));
		end
		outputQ.enq(Token {index: projected.index, data: result});
	endrule

	//------------------------------------------------------------------------------------
	// Interface
	//------------------------------------------------------------------------------------
	method Action put(Token#(ModelDim) value);
		inputQ.enq(value);
	endmethod

	method ActionValue#(Token#(ModelDim)) get;
		let value = outputQ.first;
		outputQ.deq;
		return value;
	endmethod
endmodule

endpackage
