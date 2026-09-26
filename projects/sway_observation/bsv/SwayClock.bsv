package SwayClock;

import Clocks::*;
import PLL::*;

interface SwayClockIfc;
	interface Clock clk100;
	interface Reset rst25;
	interface Reset rst100;
endinterface

// blueyosys exports !PLL_LOCK as a Reset. Convert that active-high indication
// to BSV's active-low reset and synchronize release in each destination domain.
(* no_default_clock, no_default_reset *)
module mkSwayClock#(Clock clk25)(SwayClockIfc);
	PLLIfc pll <- mkPllFast(clk25);
	Reset lockReset <- mkResetInverter(pll.rst_100mhz, clocked_by pll.clk_100mhz);
	Reset uartReset <- mkAsyncReset(2, lockReset, clk25);
	Reset coreReset <- mkAsyncReset(2, lockReset, pll.clk_100mhz);

	interface clk100 = pll.clk_100mhz;
	interface rst25 = uartReset;
	interface rst100 = coreReset;
endmodule

endpackage
