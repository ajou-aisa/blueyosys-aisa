package SwayNorm;

import Assert::*;
import FIFO::*;
import Vector::*;

import SwayTypes::*;
import SwayParameters::*;

module mkSwayNorm#(Integer blockId)(NormIfc);
	Integer weightExp = blockScale(blockId, "normWeight");
	Integer biasExp = blockScale(blockId, "normBias");
	Integer outputExp = blockScale(blockId, "norm");
	Integer commonExp = min(min(weightExp, biasExp), outputExp);
	Integer weightShift = weightExp - commonExp;
	Integer biasShift = biasExp - commonExp;
	Integer outputShift = outputExp - commonExp;
	Integer groupNum = valueOf(ModelDim) / valueOf(NormLanes);

	// |20*x-sum| <= 4845, gamma/bias <= 128, 20*(max-min) <= 5100.
	// These bounds keep the signed numerator below 2^31 and denominator below 2^32.
	staticAssert(weightShift <= 10 && biasShift <= 10 && outputShift <= 18,
		"Range-normalization scale alignment exceeds the 32-bit divider bounds");

	FIFO#(Token#(ModelDim)) inputQ <- mkFIFO1;
	FIFO#(Token#(ModelDim)) outputQ <- mkFIFO1;
	Reg#(Vector#(ModelDim, Int#(8))) inputR <- mkReg(replicate(0));
	Reg#(Vector#(ModelDim, Int#(8))) outputR <- mkReg(replicate(0));
	Reg#(Bit#(4)) indexR <- mkReg(0);
	Reg#(Int#(13)) sumR <- mkReg(0);
	Reg#(Int#(8)) minimumR <- mkReg(127);
	Reg#(Int#(8)) maximumR <- mkReg(-128);
	Reg#(Bit#(5)) channelCnt <- mkReg(0);
	Reg#(Bit#(4)) groupCnt <- mkReg(0);
	Reg#(Bit#(6)) divideCnt <- mkReg(0);
	Reg#(UInt#(32)) denominatorR <- mkReg(1);
	Reg#(Vector#(NormLanes, UInt#(32))) quotientR <- mkReg(replicate(0));
	Reg#(Vector#(NormLanes, UInt#(32))) remainderR <- mkReg(replicate(0));
	Reg#(Vector#(NormLanes, Bool)) negativeR <- mkReg(replicate(False));
	Reg#(Bool) activeOn <- mkReg(False);
	Reg#(Bool) statisticsDone <- mkReg(False);
	Reg#(Bool) divideOn <- mkReg(False);
	Reg#(Bool) roundOn <- mkReg(False);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Retain one token and collect its channel sum, minimum, and maximum.
	//------------------------------------------------------------------------------------
	rule process1 ( !activeOn );
		let value = inputQ.first;
		inputQ.deq;
		inputR <= value.data;
		indexR <= value.index;
		sumR <= 0;
		minimumR <= 127;
		maximumR <= -128;
		channelCnt <= 0;
		groupCnt <= 0;
		statisticsDone <= False;
		activeOn <= True;
	endrule

	rule process2 ( activeOn && !statisticsDone );
		Int#(8) value = inputR[channelCnt];
		sumR <= sumR + signExtend(value);
		minimumR <= value < minimumR ? value : minimumR;
		maximumR <= value > maximumR ? value : maximumR;
		if ( channelCnt == fromInteger(valueOf(ModelDim) - 1) ) begin
			statisticsDone <= True;
		end else begin
			channelCnt <= channelCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Form the exact rational affine expression; no intermediate rounding occurs.
	// Input scale cancels in (20*x-sum)/(20*(max-min)).
	//------------------------------------------------------------------------------------
	rule process3 ( activeOn && statisticsDone && !divideOn && !roundOn );
		Int#(9) span = signExtend(maximumR) - signExtend(minimumR);
		Int#(14) denominator = signExtend(span) * fromInteger(valueOf(ModelDim));
		if ( span == 0 ) begin
			denominator = 1;
		end
		Vector#(NormLanes, UInt#(32)) numerators = newVector;
		Vector#(NormLanes, Bool) negatives = newVector;
		for ( Integer lane = 0; lane < valueOf(NormLanes); lane = lane + 1 ) begin
			Bit#(6) channel = zeroExtend(groupCnt) * fromInteger(valueOf(NormLanes)) + fromInteger(lane);
			Int#(14) centered = signExtend(inputR[channel]) * fromInteger(valueOf(ModelDim)) - signExtend(sumR);
			Int#(8) weight = normWeight(blockId, channel);
			Int#(8) bias = normBias(blockId, channel);
			Int#(22) weighted = signExtend(centered) * signExtend(weight);
			Int#(22) biased = signExtend(bias) * signExtend(denominator);
			Int#(32) numerator = (signExtend(weighted) << weightShift) + (signExtend(biased) << biasShift);
			negatives[lane] = numerator < 0;
			numerators[lane] = unpack(pack(numerator < 0 ? -numerator : numerator));
		end
		denominatorR <= zeroExtend(unpack(pack(denominator))) << outputShift;
		quotientR <= numerators;
		remainderR <= replicate(0);
		negativeR <= negatives;
		divideCnt <= 0;
		divideOn <= True;
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Two unsigned restoring dividers, one quotient bit per cycle for 32 cycles.
	//------------------------------------------------------------------------------------
	rule process4 ( activeOn && divideOn );
		Vector#(NormLanes, UInt#(32)) quotients = newVector;
		Vector#(NormLanes, UInt#(32)) remainders = newVector;
		for ( Integer lane = 0; lane < valueOf(NormLanes); lane = lane + 1 ) begin
			Bit#(32) dividendBits = pack(quotientR[lane]);
			UInt#(33) trial = (zeroExtend(remainderR[lane]) << 1) | zeroExtend(unpack(dividendBits[31:31]));
			UInt#(32) quotient = quotientR[lane] << 1;
			if ( trial >= zeroExtend(denominatorR) ) begin
				trial = trial - zeroExtend(denominatorR);
				quotient = quotient | 1;
			end
			quotients[lane] = quotient;
			remainders[lane] = truncate(trial);
		end
		quotientR <= quotients;
		remainderR <= remainders;
		if ( divideCnt == 31 ) begin
			divideOn <= False;
			roundOn <= True;
		end else begin
			divideCnt <= divideCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 4]
	// Round the full rational result once, ties to even, then clamp to signed INT8.
	//------------------------------------------------------------------------------------
	rule process5 ( activeOn && roundOn && !divideOn );
		Vector#(ModelDim, Int#(8)) result = outputR;
		for ( Integer lane = 0; lane < valueOf(NormLanes); lane = lane + 1 ) begin
			UInt#(33) twiceRemainder = zeroExtend(remainderR[lane]) << 1;
			UInt#(33) quotient = zeroExtend(quotientR[lane]);
			Bit#(32) quotientBits = pack(quotientR[lane]);
			if ( twiceRemainder > zeroExtend(denominatorR)
				|| (twiceRemainder == zeroExtend(denominatorR) && quotientBits[0] == 1) ) begin
				quotient = quotient + 1;
			end
			Int#(64) signedResult = unpack(zeroExtend(pack(quotient)));
			if ( negativeR[lane] ) begin
				signedResult = -signedResult;
			end
			Bit#(6) channel = zeroExtend(groupCnt) * fromInteger(valueOf(NormLanes)) + fromInteger(lane);
			result[channel] = clip8(signedResult);
		end
		outputR <= result;
		roundOn <= False;
		if ( groupCnt == fromInteger(groupNum - 1) ) begin
			outputQ.enq(Token { index: indexR, data: result });
			activeOn <= False;
		end else begin
			groupCnt <= groupCnt + 1;
		end
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
