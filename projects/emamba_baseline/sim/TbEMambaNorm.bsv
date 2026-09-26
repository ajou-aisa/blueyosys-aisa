package TbEMambaNorm;

import RegFile::*;
import Vector::*;

import EMambaTypes::*;
import EMambaNorm::*;

module mkTbEMambaNorm(Empty);
	Integer rowsPerBlock = 6;
	Integer totalRows = 12;
	Integer totalWords = totalRows * valueOf(ModelDim);

	NormIfc norm0 <- mkEMambaNorm(0);
	NormIfc norm1 <- mkEMambaNorm(1);
	RegFile#(Bit#(8), Int#(8)) inputR <- mkRegFileLoad("generated/norm_input.hex", 0, fromInteger(totalWords - 1));
	RegFile#(Bit#(8), Int#(8)) expectedR <- mkRegFileLoad("generated/norm_expected.hex", 0, fromInteger(totalWords - 1));
	Reg#(Vector#(ModelDim, Int#(8))) valuesR <- mkRegU;
	Reg#(Token#(ModelDim)) resultR <- mkRegU;
	Reg#(Bit#(4)) rowCnt <- mkReg(0);
	Reg#(Bit#(5)) channelCnt <- mkReg(0);
	Reg#(Bit#(3)) phase <- mkReg(0);
	Reg#(UInt#(32)) cycleCnt <- mkReg(0);
	Reg#(Bit#(9)) drainCnt <- mkReg(0);

	rule tick;
		cycleCnt <= cycleCnt + 1;
	endrule

	rule watchdog ( cycleCnt > 100000 );
		$display("EMAMBA_NORM_FAIL watchdog row=%0d phase=%0d", rowCnt, phase);
		$finish(1);
	endrule

	rule loadInput ( phase == 0 );
		Bit#(8) address = zeroExtend(rowCnt) * fromInteger(valueOf(ModelDim)) + zeroExtend(channelCnt);
		Vector#(ModelDim, Int#(8)) values = valuesR;
		values[channelCnt] = inputR.sub(address);
		valuesR <= values;
		if ( channelCnt == fromInteger(valueOf(ModelDim) - 1) ) begin
			channelCnt <= 0;
			phase <= 1;
		end else
			channelCnt <= channelCnt + 1;
	endrule

	rule feed0 ( phase == 1 && rowCnt < fromInteger(rowsPerBlock) );
		norm0.put(Token {index: truncate(rowCnt), data: valuesR});
		phase <= 2;
	endrule

	rule feed1 ( phase == 1 && rowCnt >= fromInteger(rowsPerBlock) );
		norm1.put(Token {index: truncate(rowCnt - fromInteger(rowsPerBlock)), data: valuesR});
		phase <= 2;
	endrule

	rule capture0 ( phase == 2 && rowCnt < fromInteger(rowsPerBlock) );
		let result <- norm0.get;
		resultR <= result;
		phase <= 3;
	endrule

	rule capture1 ( phase == 2 && rowCnt >= fromInteger(rowsPerBlock) );
		let result <- norm1.get;
		resultR <= result;
		phase <= 3;
	endrule

	rule check ( phase == 3 );
		Bit#(4) expectedIndex = rowCnt < fromInteger(rowsPerBlock)
			? rowCnt : rowCnt - fromInteger(rowsPerBlock);
		if ( resultR.index != expectedIndex ) begin
			$display("EMAMBA_NORM_FAIL index row=%0d expected=%0d actual=%0d", rowCnt, expectedIndex, resultR.index);
			$finish(1);
		end
		Bit#(8) address = zeroExtend(rowCnt) * fromInteger(valueOf(ModelDim)) + zeroExtend(channelCnt);
		Int#(8) expected = expectedR.sub(address);
		if ( resultR.data[channelCnt] != expected ) begin
			$display("EMAMBA_NORM_FAIL mismatch row=%0d channel=%0d expected=%0d actual=%0d", rowCnt, channelCnt, expected, resultR.data[channelCnt]);
			$finish(1);
		end
		if ( channelCnt == fromInteger(valueOf(ModelDim) - 1) ) begin
			channelCnt <= 0;
			rowCnt <= rowCnt + 1;
			phase <= rowCnt == fromInteger(totalRows - 1) ? 4 : 0;
		end else
			channelCnt <= channelCnt + 1;
	endrule

	rule extra0 ( phase == 4 );
		let result <- norm0.get;
		$display("EMAMBA_NORM_FAIL extra_output block=0 index=%0d", result.index);
		$finish(1);
	endrule

	rule extra1 ( phase == 4 );
		let result <- norm1.get;
		$display("EMAMBA_NORM_FAIL extra_output block=1 index=%0d", result.index);
		$finish(1);
	endrule

	rule drain ( phase == 4 );
		drainCnt <= drainCnt + 1;
		if ( drainCnt == 255 ) begin
			$display("EMAMBA_NORM_PASS blocks=2 rows=%0d values=%0d cycles=%0d", totalRows, totalWords, cycleCnt);
			$finish(0);
		end
	endrule
endmodule

endpackage
