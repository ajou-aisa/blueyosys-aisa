package TbSway;

import RegFile::*;

import SwayTypes::*;
import SwayBaseline::*;
import GeneratedTestConfig::*;

module mkTbSway(Empty);
	Integer inputWords = valueOf(TestFrameCount) * valueOf(FrameElements);
	Integer outputWords = valueOf(TestFrameCount) * valueOf(OutputDim);
	Integer stallCycles = 8192;
	Integer drainCycles = 2048;
	Integer watchdogCycles = valueOf(TestFrameCount) * 1000000;

	SwayIfc dut <- mkSwayBaseline;
	RegFile#(Bit#(32), Int#(8)) inputR <- mkRegFileLoad(testInputPath(), 0, fromInteger(inputWords - 1));
	RegFile#(Bit#(32), Int#(8)) expectedR <- mkRegFileLoad(testExpectedPath(), 0, fromInteger(outputWords - 1));
	Reg#(UInt#(32)) sentCnt <- mkReg(0);
	Reg#(UInt#(32)) receivedCnt <- mkReg(0);
	Reg#(UInt#(64)) cycleCnt <- mkReg(0);
	Reg#(UInt#(64)) inputStartR <- mkReg(0);
	Reg#(UInt#(64)) outputStartR <- mkReg(0);
	Reg#(UInt#(64)) pauseUntilR <- mkReg(0);
	Reg#(UInt#(32)) drainCnt <- mkReg(0);
	Reg#(Bool) finishOn <- mkReg(False);

	rule tick;
		cycleCnt <= cycleCnt + 1;
	endrule

	rule watchdog ( cycleCnt > fromInteger(watchdogCycles) );
		$display("SWAY_FAIL watchdog sent=%0d outputs=%0d cycles=%0d", sentCnt, receivedCnt, cycleCnt);
		$finish(1);
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Consecutive frames with two deterministic source bubbles every 17 cycles.
	//------------------------------------------------------------------------------------
	rule process1 ( sentCnt < fromInteger(inputWords) && cycleCnt % 17 > 1 );
		dut.put(inputR.sub(pack(sentCnt)));
		sentCnt <= sentCnt + 1;
		if ( sentCnt % fromInteger(valueOf(FrameElements)) == 0 ) begin
			inputStartR <= cycleCnt;
		end
		if ( sentCnt % fromInteger(valueOf(FrameElements)) == fromInteger(valueOf(FrameElements) - 1) ) begin
			$display("SWAY_INPUT_FRAME,%0d,%0d,%0d", sentCnt / fromInteger(valueOf(FrameElements)), inputStartR, cycleCnt);
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Compare every scalar. Pause after each first output to propagate backpressure.
	//------------------------------------------------------------------------------------
	rule process2 ( !finishOn && cycleCnt >= pauseUntilR && cycleCnt % 11 != 0 );
		let value <- dut.get;
		let expected = expectedR.sub(pack(receivedCnt));
		if ( value != expected ) begin
			$display("SWAY_FAIL mismatch frame=%0d coordinate=%0d expected=%0d actual=%0d cycles=%0d",
				receivedCnt / fromInteger(valueOf(OutputDim)), receivedCnt % fromInteger(valueOf(OutputDim)), expected, value, cycleCnt);
			$finish(1);
		end
		$display("SWAY_OUTPUT,%0d,%0d,%0d", receivedCnt, value, cycleCnt);
		receivedCnt <= receivedCnt + 1;
		if ( receivedCnt % fromInteger(valueOf(OutputDim)) == 0 ) begin
			outputStartR <= cycleCnt;
			pauseUntilR <= cycleCnt + fromInteger(stallCycles + 1);
			$display("SWAY_STALL,%0d,%0d,%0d", receivedCnt / fromInteger(valueOf(OutputDim)),
				cycleCnt + 1, cycleCnt + fromInteger(stallCycles + 1));
		end
		if ( receivedCnt % fromInteger(valueOf(OutputDim)) == fromInteger(valueOf(OutputDim) - 1) ) begin
			$display("SWAY_FRAME,%0d,%0d,%0d", receivedCnt / fromInteger(valueOf(OutputDim)), outputStartR, cycleCnt);
		end
		if ( receivedCnt + 1 == fromInteger(outputWords) ) begin
			finishOn <= True;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Keep the sink ready after completion; unexpected queued or trailing output fails.
	//------------------------------------------------------------------------------------
	rule process3 ( finishOn );
		let value <- dut.get;
		$display("SWAY_FAIL extra_output actual=%0d cycles=%0d", value, cycleCnt);
		$finish(1);
	endrule

	rule process4 ( finishOn && drainCnt < fromInteger(drainCycles) );
		drainCnt <= drainCnt + 1;
	endrule

	rule process5 ( finishOn && drainCnt == fromInteger(drainCycles) );
		if ( sentCnt != fromInteger(inputWords) ) begin
			$display("SWAY_FAIL premature_completion sent=%0d expected=%0d", sentCnt, inputWords);
			$finish(1);
		end else begin
			$display("SWAY_PASS frames=%0d outputs=%0d cycles=%0d drain_cycles=%0d",
				valueOf(TestFrameCount), receivedCnt, cycleCnt, drainCnt);
			$finish(0);
		end
	endrule
endmodule

endpackage
