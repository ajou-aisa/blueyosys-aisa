package HwMain;

import FIFO::*;

import SwayTypes::*;
import SwayBaseline::*;


interface HwMainIfc;
	method ActionValue#(Bit#(8)) serial_tx;
	method Action serial_rx(Bit#(8) data);
endinterface


// The project Top supplies the UART and clock crossing.
// One request is 320 signed INT8 bytes in HWC order; its reply is 57 bytes.
// The host sends a complete frame and reads its reply before the next frame.
// The baseline keeps its parameters and state on chip.
module mkHwMain(HwMainIfc);
	FIFO#(Bit#(8)) serialRxQ <- mkFIFO;
	FIFO#(Bit#(8)) serialTxQ <- mkFIFO;

	SwayIfc core <- mkSwayBaseline;

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Forward received INT8 values to the baseline input queue.
	//------------------------------------------------------------------------------------
	rule process1;
		let value = serialRxQ.first;
		serialRxQ.deq;
		core.put(unpack(value));
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Return coordinates through the UART output queue.
	//------------------------------------------------------------------------------------
	rule process2;
		let value <- core.get;
		serialTxQ.enq(pack(value));
	endrule

	//------------------------------------------------------------------------------------
	// Interface
	//------------------------------------------------------------------------------------
	method ActionValue#(Bit#(8)) serial_tx;
		let value = serialTxQ.first;
		serialTxQ.deq;
		return value;
	endmethod

	method Action serial_rx(Bit#(8) data);
		serialRxQ.enq(data);
	endmethod
endmodule

endpackage
