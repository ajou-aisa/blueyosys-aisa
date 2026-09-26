package SwayBaseline;

import Vector::*;
import FIFO::*;

import SwayTypes::*;
import SwayParameters::*;
import SwayLinear::*;
import SwayBlock::*;

// Fixed-weight MARS graph. Each affine/normalization/scan stage has its own
// engine. FIFOs permit adjacent tokens and independent frames to overlap.
module mkSwayBaseline(SwayIfc);
	FIFO#(Int#(8)) inputQ <- mkSizedFIFO(valueOf(SerialFifoDepth));
	FIFO#(Int#(8)) outputQ <- mkSizedFIFO(valueOf(SerialFifoDepth));
	FIFO#(Vector#(FrameElements, Int#(8))) frameQ <- mkFIFO1;
	Reg#(Vector#(FrameElements, Int#(8))) inputR <- mkRegU;
	Reg#(Bit#(9)) inputCnt <- mkReg(0);

	LinearIfc#(PatchElements, ModelDim) embedding <- mkSwayLinear(0);
	BlockIfc block0 <- mkSwayBlock(0);
	BlockIfc block1 <- mkSwayBlock(1);
	LinearIfc#(HeadInputDim, ModelDim) headHidden <- mkSwayLinear(9);
	LinearIfc#(ModelDim, OutputDim) headOutput <- mkSwayLinear(10);

	Reg#(Vector#(FrameElements, Int#(8))) frameR <- mkRegU;
	Reg#(Bool) patchOn <- mkReg(False);
	Reg#(Bit#(4)) patchCnt <- mkReg(0);
	Vector#(TokenNum, Reg#(Vector#(ModelDim, Int#(8)))) headR <- replicateM(mkRegU);
	Reg#(Vector#(OutputDim, Int#(8))) resultR <- mkRegU;
	Reg#(Bool) outputOn <- mkReg(False);
	Reg#(Bit#(6)) outputCnt <- mkReg(0);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Collect one HWC frame and form row-major 2x2x5 patches.
	//------------------------------------------------------------------------------------
	rule process1;
		Vector#(FrameElements, Int#(8)) nextInput = inputR;
		nextInput[inputCnt] = inputQ.first;
		inputQ.deq;
		inputR <= nextInput;
		if ( inputCnt == fromInteger(valueOf(FrameElements) - 1) ) begin
			frameQ.enq(nextInput);
			inputCnt <= 0;
		end else begin
			inputCnt <= inputCnt + 1;
		end
	endrule

	rule process2 ( !patchOn );
		frameR <= frameQ.first;
		frameQ.deq;
		patchCnt <= 0;
		patchOn <= True;
	endrule

	rule process3 ( patchOn );
		Vector#(TokenNum, Vector#(PatchElements, Int#(8))) patches = newVector;
		for ( Integer p = 0; p < valueOf(TokenNum); p = p + 1 ) begin
			for ( Integer i = 0; i < valueOf(PatchElements); i = i + 1 ) begin
				Integer patchRow = p / valueOf(PatchColumns);
				Integer patchColumn = p % valueOf(PatchColumns);
				Integer row = valueOf(PatchSide) * patchRow
					+ i / (valueOf(PatchSide) * valueOf(InputChannels));
				Integer column = valueOf(PatchSide) * patchColumn
					+ (i / valueOf(InputChannels)) % valueOf(PatchSide);
				Integer channel = i % valueOf(InputChannels);
				Integer address = (row * valueOf(InputWidth) + column)
					* valueOf(InputChannels) + channel;
				patches[p][i] = requant(signExtend(frameR[address]), nodeScale("input"), nodeScale("patches"));
			end
		end
		embedding.put(Token { index: patchCnt, data: patches[patchCnt] });
		if ( patchCnt == fromInteger(valueOf(TokenNum) - 1) ) begin
			patchOn <= False;
		end else begin
			patchCnt <= patchCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Two dedicated Mamba block pipelines.
	//------------------------------------------------------------------------------------
	rule process4;
		let value <- embedding.get;
		block0.put(value);
	endrule

	rule process5;
		let value <- block0.get;
		block1.put(value);
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Flatten all token positions, regress 57 coordinates, serialize.
	//------------------------------------------------------------------------------------
	rule process6;
		let value <- block1.get;
		Vector#(ModelDim, Int#(8)) token = newVector;
		for ( Integer i = 0; i < valueOf(ModelDim); i = i + 1 ) begin
			token[i] = requant(signExtend(value.data[i]),
				blockScale(1, "residual"), nodeScale("headInput"));
		end
		headR[value.index] <= token;
		if ( value.index == fromInteger(valueOf(TokenNum) - 1) ) begin
			Vector#(HeadInputDim, Int#(8)) flattened = newVector;
			for ( Integer p = 0; p < valueOf(TokenNum); p = p + 1 ) begin
				Vector#(ModelDim, Int#(8)) stored = p == valueOf(TokenNum) - 1 ? token : headR[p];
				for ( Integer i = 0; i < valueOf(ModelDim); i = i + 1 ) begin
					flattened[p * valueOf(ModelDim) + i] = stored[i];
				end
			end
			headHidden.put(Token { index: 0, data: flattened });
		end
	endrule

	rule process7;
		Token#(ModelDim) value <- headHidden.get;
		for ( Integer i = 0; i < valueOf(ModelDim); i = i + 1 ) begin
			Int#(8) relu = value.data[i] < 0 ? 0 : value.data[i];
			value.data[i] = requant(signExtend(relu), nodeScale("headHidden"), nodeScale("headActivation"));
		end
		headOutput.put(value);
	endrule

	rule process8 ( !outputOn );
		let value <- headOutput.get;
		resultR <= value.data;
		outputCnt <= 0;
		outputOn <= True;
	endrule

	rule process9 ( outputOn );
		outputQ.enq(resultR[outputCnt]);
		if ( outputCnt == fromInteger(valueOf(OutputDim) - 1) ) begin
			outputOn <= False;
		end else begin
			outputCnt <= outputCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// Interface
	//------------------------------------------------------------------------------------
	method Action put(Int#(8) value);
		inputQ.enq(value);
	endmethod

	method ActionValue#(Int#(8)) get;
		let value = outputQ.first;
		outputQ.deq;
		return value;
	endmethod
endmodule

endpackage
