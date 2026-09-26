package EMambaNorm;

import FIFO::*;
import Vector::*;

import EMambaTypes::*;
import EMambaParameters::*;

module mkEMambaNorm#(Integer blockId)(NormIfc);
	Integer weightExp = blockScale(blockId, "normWeight");
	Integer biasExp = blockScale(blockId, "normBias");
	Integer outputExp = blockScale(blockId, "norm");
	Integer scaledExp = weightExp - 24;
	Integer commonExp = scaledExp < biasExp ? scaledExp : biasExp;

	FIFO#(Token#(ModelDim)) inputQ <- mkFIFO1;
	FIFO#(Token#(ModelDim)) outputQ <- mkFIFO1;
	Reg#(Vector#(ModelDim, Int#(8))) inputR <- mkReg(replicate(0));
	Reg#(Vector#(ModelDim, Int#(8))) outputR <- mkReg(replicate(0));
	Reg#(Bit#(4)) indexR <- mkReg(0);
	Reg#(Int#(13)) sumR <- mkReg(0);
	Reg#(Int#(8)) minimumR <- mkReg(127);
	Reg#(Int#(8)) maximumR <- mkReg(-128);
	Reg#(Bit#(5)) channelCnt <- mkReg(0);
	Reg#(Bit#(5)) groupCnt <- mkReg(0);
	Reg#(Bit#(7)) divideCnt <- mkReg(0);
	Reg#(UInt#(64)) denominatorR <- mkReg(1);
	Reg#(UInt#(64)) quotientR <- mkReg(0);
	Reg#(UInt#(64)) remainderR <- mkReg(0);
	Reg#(Bool) negativeR <- mkReg(False);
	Reg#(Bool) activeOn <- mkReg(False);
	Reg#(Bool) statisticsDone <- mkReg(False);
	Reg#(Bool) divideOn <- mkReg(False);
	Reg#(Bool) roundOn <- mkReg(False);

	rule collect ( !activeOn );
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

	rule statistics ( activeOn && !statisticsDone );
		Int#(8) value = inputR[channelCnt];
		sumR <= sumR + signExtend(value);
		minimumR <= value < minimumR ? value : minimumR;
		maximumR <= value > maximumR ? value : maximumR;
		if ( channelCnt == fromInteger(valueOf(ModelDim) - 1) )
			statisticsDone <= True;
		else
			channelCnt <= channelCnt + 1;
	endrule

	// QRangeNorm rounds the mean in 24-bit fixed point before centering.
	rule prepare ( activeOn && statisticsDone && !divideOn && !roundOn );
		Int#(64) total = signExtend(sumR) << 24;
		UInt#(64) magnitude = unpack(pack(total < 0 ? -total : total));
		UInt#(64) meanMagnitude = magnitude / fromInteger(valueOf(ModelDim));
		UInt#(64) leftover = magnitude % fromInteger(valueOf(ModelDim));
		Bit#(64) meanBits = pack(meanMagnitude);
		if ( leftover * 2 > fromInteger(valueOf(ModelDim))
			|| (leftover * 2 == fromInteger(valueOf(ModelDim)) && meanBits[0] == 1) )
			meanMagnitude = meanMagnitude + 1;
		Int#(64) mean = unpack(pack(meanMagnitude));
		if ( total < 0 ) mean = -mean;
		Bit#(6) channel = zeroExtend(groupCnt);
		Int#(64) centered = (signExtend(inputR[channel]) << 24) - mean;
		Int#(64) span = (signExtend(maximumR) - signExtend(minimumR)) << 24;
		Int#(64) denominator = span > fromInteger(normEpsilonCode(blockId))
			? span : fromInteger(normEpsilonCode(blockId));
		Int#(64) numerator = centered << 24;
		quotientR <= unpack(pack(numerator < 0 ? -numerator : numerator));
		denominatorR <= unpack(pack(denominator));
		remainderR <= 0;
		negativeR <= numerator < 0;
		divideCnt <= 0;
		divideOn <= True;
	endrule

	// One unsigned quotient bit per cycle. Only the normalized ratio is divided.
	rule divide ( activeOn && divideOn );
		Bit#(64) dividendBits = pack(quotientR);
		UInt#(65) trial = (zeroExtend(remainderR) << 1) | zeroExtend(unpack(dividendBits[63:63]));
		UInt#(64) quotient = quotientR << 1;
		if ( trial >= zeroExtend(denominatorR) ) begin
			trial = trial - zeroExtend(denominatorR);
			quotient = quotient | 1;
		end
		quotientR <= quotient;
		remainderR <= truncate(trial);
		if ( divideCnt == 63 ) begin
			divideOn <= False;
			roundOn <= True;
		end else
			divideCnt <= divideCnt + 1;
	endrule

	rule finishChannel ( activeOn && roundOn && !divideOn );
		UInt#(65) twiceRemainder = zeroExtend(remainderR) << 1;
		UInt#(65) normalizedMagnitude = zeroExtend(quotientR);
		Bit#(64) quotientBits = pack(quotientR);
		if ( twiceRemainder > zeroExtend(denominatorR)
			|| (twiceRemainder == zeroExtend(denominatorR) && quotientBits[0] == 1) )
			normalizedMagnitude = normalizedMagnitude + 1;
		Int#(64) normalized = unpack(truncate(pack(normalizedMagnitude)));
		if ( negativeR ) normalized = -normalized;
		Bit#(6) channel = zeroExtend(groupCnt);
		Int#(64) scaled = normalized * signExtend(normWeight(blockId, channel));
		Int#(64) affine = shiftRound(scaled, scaledExp, commonExp)
			+ shiftRound(signExtend(normBias(blockId, channel)), biasExp, commonExp);
		Vector#(ModelDim, Int#(8)) result = outputR;
		result[channel] = requant(affine, commonExp, outputExp);
		outputR <= result;
		roundOn <= False;
		if ( groupCnt == fromInteger(valueOf(ModelDim) - 1) ) begin
			outputQ.enq(Token { index: indexR, data: result });
			activeOn <= False;
		end else
			groupCnt <= groupCnt + 1;
	endrule

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
