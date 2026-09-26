package QuantizedMult18x18D;

import FIFO::*;
import FIFOF::*;

import QuantizedMath::*;


typedef 3 QuantizedMult18x18DLatency;
typedef 8 QuantizedMult18x18DQueueDepth;
typedef 4 QuantizedMult18x18DCountWidth;


interface QuantizedMult18x18DImportIfc;
	method Action putA(Bit#(18) data);
	method Action putB(Bit#(18) data);
	method Bit#(36) dataOut;
endinterface

import "BVI" quantized_mult18x18d =
module mkQuantizedMult18x18DImport#(Clock clk, Reset rstn)
	(QuantizedMult18x18DImportIfc);
	default_clock no_clock;
	default_reset no_reset;

	input_clock (clk) = clk;
	input_reset (rstn) = rstn;

	method dataout dataOut;
	method putA(dataax) enable((*inhigh*) dataaxEnable)
		reset_by(no_reset) clocked_by(clk);
	method putB(dataay) enable((*inhigh*) dataayEnable)
		reset_by(no_reset) clocked_by(clk);

	schedule (
		dataOut, putA, putB
	) CF (
		dataOut, putA, putB
	);
endmodule


interface QuantizedMult18x18DBSIMIfc;
	method Action putA(Bit#(18) data);
	method Action putB(Bit#(18) data);
	method ActionValue#(Bit#(36)) dataOut;
endinterface

module mkQuantizedMult18x18DBSIM(QuantizedMult18x18DBSIMIfc);
	FIFO#(Bit#(18)) inputAQ <-
		mkSizedFIFO(valueOf(QuantizedMult18x18DQueueDepth));
	FIFO#(Bit#(18)) inputBQ <-
		mkSizedFIFO(valueOf(QuantizedMult18x18DQueueDepth));

	method Action putA(Bit#(18) data);
		inputAQ.enq(data);
	endmethod

	method Action putB(Bit#(18) data);
		inputBQ.enq(data);
	endmethod

	method ActionValue#(Bit#(36)) dataOut;
		let inputABits = inputAQ.first;
		let inputBBits = inputBQ.first;
		inputAQ.deq;
		inputBQ.deq;

		Int#(18) inputA = unpack(inputABits);
		Int#(18) inputB = unpack(inputBBits);
		Int#(36) inputAExt = signExtend(inputA);
		Int#(36) inputBExt = signExtend(inputB);
		Int#(36) product = inputAExt * inputBExt;
		return pack(product);
	endmethod
endmodule


module mkQuantizedMult18x18D(Int16MultiplyIfc);
	Clock curclk <- exposeCurrentClock;
	Reset currst <- exposeCurrentReset;

`ifdef BSIM
	QuantizedMult18x18DBSIMIfc multiplier <- mkQuantizedMult18x18DBSIM;
`else
	QuantizedMult18x18DImportIfc multiplier <-
		mkQuantizedMult18x18DImport(curclk, currst);
`endif

	FIFOF#(QInt16Product) outputQ <-
		mkSizedFIFOF(valueOf(QuantizedMult18x18DQueueDepth));
	Wire#(Bit#(1)) validWire <- mkDWire(0);
	Reg#(Bit#(QuantizedMult18x18DLatency)) validMap <- mkReg(0);
	Wire#(Bit#(18)) inputA <- mkDWire(0);
	Wire#(Bit#(18)) inputB <- mkDWire(0);

	//------------------------------------------------------------------------------------
	// [STAGE 1-3]
	// Advance the DSP input, pipeline, and output registers and track valid products
	//------------------------------------------------------------------------------------
	rule advancePipeline;
`ifdef BSIM
		if ( validWire != 0 ) begin
			multiplier.putA(inputA);
			multiplier.putB(inputB);
		end
`else
		multiplier.putA(inputA);
		multiplier.putB(inputB);
`endif

		validMap <= (validMap << 1) | zeroExtend(validWire);
		if ( validMap[valueOf(QuantizedMult18x18DLatency) - 1] == 1 ) begin
`ifdef BSIM
			let productBits <- multiplier.dataOut;
`else
			let productBits = multiplier.dataOut;
`endif
			Int#(36) product = unpack(productBits);
			outputQ.enq(truncate(product));
		end
	endrule

	Reg#(Bit#(QuantizedMult18x18DCountWidth)) dataInFlightUp <- mkReg(0);
	Reg#(Bit#(QuantizedMult18x18DCountWidth)) dataInFlightDn <- mkReg(0);

	method Action put(QInt16 a, QInt16 b)
		if ( dataInFlightUp - dataInFlightDn <
			fromInteger(valueOf(QuantizedMult18x18DQueueDepth)) );
		Int#(18) inputAExt = signExtend(a);
		Int#(18) inputBExt = signExtend(b);
		inputA <= pack(inputAExt);
		inputB <= pack(inputBExt);
		validWire <= 1;
		dataInFlightUp <= dataInFlightUp + 1;
	endmethod

	method ActionValue#(QInt16Product) get;
		outputQ.deq;
		dataInFlightDn <= dataInFlightDn + 1;
		return outputQ.first;
	endmethod
endmodule

endpackage: QuantizedMult18x18D
