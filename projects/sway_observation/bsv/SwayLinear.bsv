package SwayLinear;

import Assert::*;
import FIFO::*;
import Vector::*;

import SwayTypes::*;
import SwayParameters::*;

module mkSwayLinear#(Integer layerId)(LinearIfc#(n, m));
	staticAssert(valueOf(LinearLanes) == 4, "Generated weight banks require four linear lanes");
	Integer inputNum = valueOf(n);
	Integer outputNum = valueOf(m);
	Integer groupNum = (outputNum + valueOf(LinearLanes) - 1) / valueOf(LinearLanes);
	Integer productExp = layerInputScale(layerId) + layerWeightScale(layerId);
	Integer biasExp = layerBiasScale(layerId);
	Integer commonExp = layerHasBias(layerId) && biasExp < productExp ? biasExp : productExp;
	Integer outputExp = layerOutputScale(layerId);
	staticAssert(inputNum > 0 && inputNum <= valueOf(HeadInputDim) && outputNum > 0 && outputNum <= valueOf(ExpandedDim),
		"Affine dimensions exceed this fixed-model implementation");

	FIFO#(Token#(n)) inputQ <- mkFIFO1;
	FIFO#(Token#(m)) outputQ <- mkFIFO1;
	FIFO#(Tuple2#(Vector#(LinearLanes, Int#(16)), Bool)) productQ <- mkFIFO;
	FIFO#(Tuple2#(Vector#(LinearLanes, Int#(32)), Bit#(7))) sumQ <- mkFIFO;

	Reg#(Vector#(n, Int#(8))) inputR <- mkReg(replicate(0));
	Reg#(Vector#(m, Int#(8))) outputR <- mkReg(replicate(0));
	Reg#(Vector#(LinearLanes, Int#(32))) sumR <- mkReg(replicate(0));
	Reg#(Bit#(4)) indexR <- mkReg(0);
	Reg#(Bit#(9)) inputCnt <- mkReg(0);
	Reg#(Bit#(7)) groupCnt <- mkReg(0);
	Reg#(Bool) activeOn <- mkReg(False);
	Reg#(Bool) issueOn <- mkReg(False);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Retain one token while the four output lanes visit each row group.
	//------------------------------------------------------------------------------------
	rule process1 ( !activeOn );
		let value = inputQ.first;
		inputQ.deq;
		inputR <= value.data;
		indexR <= value.index;
		inputCnt <= 0;
		groupCnt <= 0;
		sumR <= replicate(0);
		activeOn <= True;
		issueOn <= True;
	endrule

	// Each lane owns one fixed weight ROM. The product FIFO is the multiplier register.
	rule process2 ( activeOn && issueOn );
		Bit#(13) address = zeroExtend(groupCnt) * fromInteger(inputNum) + zeroExtend(inputCnt);
		Int#(8) inputValue = inputR[inputCnt];
		Vector#(LinearLanes, Int#(16)) products = newVector;
		for ( Integer lane = 0; lane < valueOf(LinearLanes); lane = lane + 1 ) begin
			Int#(8) weight = linearWeight(layerId, lane, address);
			products[lane] = signExtend(inputValue) * signExtend(weight);
		end
		Bool lastInput = inputCnt == fromInteger(inputNum - 1);
		productQ.enq(tuple2(products, lastInput));
		if ( lastInput ) begin
			issueOn <= False;
		end else begin
			inputCnt <= inputCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Accumulate all products, including the final queued product, before advancing.
	// At most 320 signed INT8 products have magnitude 5242880, within Int#(32).
	//------------------------------------------------------------------------------------
	rule process3 ( activeOn && !tpl_2(productQ.first) );
		let value = productQ.first;
		productQ.deq;
		Vector#(LinearLanes, Int#(32)) sums = newVector;
		for ( Integer lane = 0; lane < valueOf(LinearLanes); lane = lane + 1 ) begin
			sums[lane] = sumR[lane] + signExtend(tpl_1(value)[lane]);
		end
		sumR <= sums;
	endrule

	// Only the final-product rule restarts the issuer. Its !issueOn guard makes
	// this control update disjoint from process2; ordinary MACs overlap issue.
	rule process3Last ( activeOn && !issueOn && tpl_2(productQ.first) );
		let value = productQ.first;
		productQ.deq;
		Vector#(LinearLanes, Int#(32)) sums = newVector;
		for ( Integer lane = 0; lane < valueOf(LinearLanes); lane = lane + 1 ) begin
			sums[lane] = sumR[lane] + signExtend(tpl_1(value)[lane]);
		end
		sumQ.enq(tuple2(sums, groupCnt));
		sumR <= replicate(0);
		if ( groupCnt + 1 < fromInteger(groupNum) ) begin
			groupCnt <= groupCnt + 1;
			inputCnt <= 0;
			issueOn <= True;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Align product and bias exactly, then perform one ties-to-even INT8 requantization.
	//------------------------------------------------------------------------------------
	rule process4 ( activeOn );
		let value = sumQ.first;
		sumQ.deq;
		Vector#(m, Int#(8)) result = outputR;
		for ( Integer lane = 0; lane < valueOf(LinearLanes); lane = lane + 1 ) begin
			Bit#(9) row = zeroExtend(tpl_2(value)) * fromInteger(valueOf(LinearLanes)) + fromInteger(lane);
			Int#(64) affine = signExtend(tpl_1(value)[lane]);
			affine = affine << (productExp - commonExp);
			if ( layerHasBias(layerId) ) begin
				Int#(64) bias = signExtend(linearBias(layerId, row));
				affine = affine + (bias << (biasExp - commonExp));
			end
			if ( row < fromInteger(outputNum) ) begin
				result[row] = requant(affine, commonExp, outputExp);
			end
		end
		outputR <= result;
		if ( tpl_2(value) == fromInteger(groupNum - 1) ) begin
			outputQ.enq(Token { index: indexR, data: result });
			activeOn <= False;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Interface
	//------------------------------------------------------------------------------------
	method Action put(Token#(n) value);
		inputQ.enq(value);
	endmethod

	method ActionValue#(Token#(m)) get;
		let value = outputQ.first;
		outputQ.deq;
		return value;
	endmethod
endmodule

endpackage
