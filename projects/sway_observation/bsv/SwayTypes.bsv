package SwayTypes;

import Vector::*;

// Fixed MARS dimensions. These aliases describe the baseline hardware;
// changing them requires matching generated parameters and counter widths.
typedef 8 InputHeight;
typedef 8 InputWidth;
typedef 5 InputChannels;
typedef 2 PatchSide;
typedef TDiv#(InputHeight, PatchSide) PatchRows;
typedef TDiv#(InputWidth, PatchSide) PatchColumns;
typedef TMul#(TMul#(InputHeight, InputWidth), InputChannels) FrameElements;
typedef TMul#(TMul#(PatchSide, PatchSide), InputChannels) PatchElements;
typedef TMul#(PatchRows, PatchColumns) TokenNum;

typedef 20 ModelDim;
typedef TMul#(2, ModelDim) InnerDim;
typedef 8 StateDim;
typedef 2 DeltaRank;
typedef TMul#(2, InnerDim) ExpandedDim;
typedef TAdd#(DeltaRank, TMul#(2, StateDim)) ProjectionDim;
typedef TMul#(TokenNum, ModelDim) HeadInputDim;
typedef 19 JointNum;
typedef TMul#(3, JointNum) OutputDim;

// Parallelism and queue depths are the original baseline allocation.
typedef 4 LinearLanes;
typedef 2 NormLanes;
typedef 4 ConvTaps;
typedef TSub#(ConvTaps, 1) ConvHistory;
typedef 32 SerialFifoDepth;
typedef 4 ResidualSlots;

typedef struct {
	Bit#(4) index;
	Vector#(n, Int#(8)) data;
} Token#(numeric type n) deriving (Bits, Eq, FShow);

interface LinearIfc#(numeric type n, numeric type m);
	method Action put(Token#(n) value);
	method ActionValue#(Token#(m)) get;
endinterface

interface NormIfc;
	method Action put(Token#(ModelDim) value);
	method ActionValue#(Token#(ModelDim)) get;
endinterface

interface BlockIfc;
	method Action put(Token#(ModelDim) value);
	method ActionValue#(Token#(ModelDim)) get;
endinterface

interface SwayIfc;
	// 320 signed INT8 elements per frame, HWC order, scale from nodeScale("input").
	method Action put(Int#(8) value);
	// 57 signed INT8 coordinates per frame, all X then Y then Z.
	method ActionValue#(Int#(8)) get;
endinterface

// Power-of-two scaling uses nearest ties-to-even, also for negative operands.
function Int#(64) shiftRound(Int#(64) value, Integer fromExp, Integer toExp);
	Int#(64) result = value;
	if ( fromExp >= toExp ) begin
		result = value << (fromExp - toExp);
	end else begin
		Integer shift = toExp - fromExp;
		UInt#(64) magnitude = unpack(pack(value < 0 ? -value : value));
		UInt#(64) quotient = magnitude >> shift;
		UInt#(64) remainder = magnitude - (quotient << shift);
		UInt#(64) half = fromInteger(2 ** (shift - 1));
		Bit#(64) quotientBits = pack(quotient);
		if ( remainder > half || (remainder == half && quotientBits[0] == 1) ) begin
			quotient = quotient + 1;
		end
		result = unpack(pack(quotient));
		if ( value < 0 ) begin
			result = -result;
		end
	end
	return result;
endfunction

function Int#(8) clip8(Int#(64) value);
	return value > 127 ? 127 : (value < -128 ? -128 : truncate(value));
endfunction

function Int#(24) clip24(Int#(64) value);
	return value > 8388607 ? 8388607 : (value < -8388608 ? -8388608 : truncate(value));
endfunction

function Int#(8) requant(Int#(64) value, Integer fromExp, Integer toExp);
	Int#(8) result = 0;
	if ( fromExp >= toExp ) begin
		result = clip8(value << (fromExp - toExp));
	end else begin
		Integer shift = toExp - fromExp;
		Int#(64) floorValue = value >> shift;
		Bit#(64) remainder = pack(value) & fromInteger((2 ** shift) - 1);
		Bit#(64) half = fromInteger(2 ** (shift - 1));
		Bit#(64) quotientBits = pack(floorValue);
		Bool increment = remainder > half || (remainder == half && quotientBits[0] == 1);
		// Clamp before the increment. The remaining quotient fits in nine bits;
		// arithmetic-floor rounding also handles negative ties without a wide negate.
		if ( floorValue >= 127 ) begin
			result = 127;
		end else if ( floorValue <= -129 ) begin
			result = -128;
		end else begin
			Int#(9) rounded = truncate(floorValue);
			if ( increment ) begin
				rounded = rounded + 1;
			end
			result = truncate(rounded);
		end
	end
	return result;
endfunction

endpackage
