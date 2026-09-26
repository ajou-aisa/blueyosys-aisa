package Top;

import Clocks::*;

import Uart::*;

import SwayClock::*;
import HwMain::*;


typedef 16 UartCdcDepth;

interface SwayTopIfc;
	(* always_ready *)
	method Bit#(1) ftdi_rxd;
	(* always_enabled, always_ready, prefix = "", result = "serial_txd" *)
	method Action ftdi_tx(Bit#(1) ftdi_txd);
	(* always_ready, prefix = "", result = "led" *)
	method Bit#(8) led;
endinterface


// Retain the initial baseline's active-low PLL reset conversion and per-domain
// synchronized release. UART transfer is outside the kernel cycle measurement.
(* no_default_clock, no_default_reset *)
module mkTop#(Clock clk_25mhz)(SwayTopIfc);
	SwayClockIfc clocks <- mkSwayClock(clk_25mhz);
	// 25 MHz / 217 gives the existing blueYosys 115200-baud UART interface.
	UartIfc uart <- mkUart(217, clocked_by clk_25mhz, reset_by clocks.rst25);
	SyncFIFOIfc#(Bit#(8)) rxQ <- mkSyncFIFO(valueOf(UartCdcDepth),
		clk_25mhz, clocks.rst25, clocks.clk100);
	SyncFIFOIfc#(Bit#(8)) txQ <- mkSyncFIFO(valueOf(UartCdcDepth),
		clocks.clk100, clocks.rst100, clk_25mhz);
	HwMainIfc main <- mkHwMain(clocked_by clocks.clk100, reset_by clocks.rst100);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Receive UART bytes and cross into the core clock domain.
	//------------------------------------------------------------------------------------
	rule uartInput;
		let value <- uart.user.get;
		rxQ.enq(value);
	endrule

	rule process1;
		let value = rxQ.first;
		rxQ.deq;
		main.serial_rx(value);
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Return coordinates through the core-to-UART clock crossing.
	//------------------------------------------------------------------------------------
	rule process2;
		let value <- main.serial_tx;
		txQ.enq(value);
	endrule

	rule uartOutput;
		uart.user.send(txQ.first);
		txQ.deq;
	endrule

	//------------------------------------------------------------------------------------
	// Interface
	//------------------------------------------------------------------------------------
	method Bit#(1) ftdi_rxd;
		return uart.serial_txd;
	endmethod

	method Action ftdi_tx(Bit#(1) ftdi_txd);
		uart.serial_rx(ftdi_txd);
	endmethod

	method Bit#(8) led;
		return 8'h01;
	endmethod
endmodule

endpackage
