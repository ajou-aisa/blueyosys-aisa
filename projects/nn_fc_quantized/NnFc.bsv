import FIFO::*;
import RegFile::*;
import Vector::*;

import QuantizedMath::*;
import QuantizedMult18x18D::*;


typedef 4 PackedPipelineDepth;
typedef 64 PackedResultQueueDepth;


typedef struct {
	Bit#(16) inputWord;
	Bit#(16) weightWord;
	Bit#(8) inputIdx;
	Bit#(6) outputIdx;
	Bit#(5) width;
	Bool firstGroup;
	Bool lastGroup;
} PackedMacRequest deriving (Eq, Bits);

typedef struct {
	Bit#(8) inputIdx;
	Bit#(6) outputIdx;
	Bool firstGroup;
	Bool lastGroup;
} PackedMacMetadata deriving (Eq, Bits);

typedef struct {
	Vector#(4, Int#(32)) laneProducts;
	Bit#(8) inputIdx;
	Bit#(6) outputIdx;
	Bit#(5) width;
	Bool firstGroup;
	Bool lastGroup;
} PackedMacProducts deriving (Eq, Bits);

typedef struct {
	Int#(64) partialSum;
	Bit#(8) inputIdx;
	Bit#(6) outputIdx;
	Bit#(5) width;
	Bool firstGroup;
	Bool lastGroup;
} PackedMacPartial deriving (Eq, Bits);


function Bool isSupportedQuantizedWidth(Bit#(5) width);
	return width == 4 || width == 8 || width == 16;
endfunction


interface NnFcIfc;
	method Action setWidth(Bit#(5) width);
	method Action putPacked(
		Bit#(16) inputWord,
		Bit#(16) weightWord,
		Bit#(8) inputIdx,
		Bit#(6) outputIdx,
		Bool firstGroup,
		Bool lastGroup
	);
	method ActionValue#(Tuple3#(Int#(32), Bit#(8), Bit#(8))) dataOut;
endinterface


(* synthesize *)
module mkNnFc(NnFcIfc);
	FIFO#(PackedMacRequest) requestQ <-
		mkSizedFIFO(valueOf(PackedPipelineDepth));
	FIFO#(PackedMacMetadata) int8MetadataQ <-
		mkSizedFIFO(valueOf(QuantizedMult18x18DQueueDepth));
	FIFO#(PackedMacMetadata) int16MetadataQ <-
		mkSizedFIFO(valueOf(QuantizedMult18x18DQueueDepth));
	FIFO#(PackedMacProducts) productQ <-
		mkSizedFIFO(valueOf(PackedPipelineDepth));
	FIFO#(PackedMacPartial) partialQ <-
		mkSizedFIFO(valueOf(PackedPipelineDepth));
	FIFO#(Tuple3#(Int#(32), Bit#(8), Bit#(8))) outputQ <-
		mkSizedFIFO(valueOf(PackedResultQueueDepth));

	Int16MultiplyIfc dspMultiplier0 <- mkQuantizedMult18x18D;
	Int16MultiplyIfc dspMultiplier1 <- mkQuantizedMult18x18D;
	RegFile#(Bit#(6), Int#(64)) accumulatorFile <- mkRegFileFull;
	Reg#(Bit#(5)) quantizedWidth <- mkReg(8);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Unpack and execute four combinational INT4 multiplications
	//------------------------------------------------------------------------------------
	rule processMultiplyInt4 ( quantizedWidth == 4 );
		requestQ.deq;
		let request = requestQ.first;
		Vector#(4, Int#(32)) products = replicate(0);

		QInt4 input0 = unpack(request.inputWord[3:0]);
		QInt4 input1 = unpack(request.inputWord[7:4]);
		QInt4 input2 = unpack(request.inputWord[11:8]);
		QInt4 input3 = unpack(request.inputWord[15:12]);
		QInt4 weight0 = unpack(request.weightWord[3:0]);
		QInt4 weight1 = unpack(request.weightWord[7:4]);
		QInt4 weight2 = unpack(request.weightWord[11:8]);
		QInt4 weight3 = unpack(request.weightWord[15:12]);

		products[0] = signExtend(multiplyInt4(input0, weight0));
		products[1] = signExtend(multiplyInt4(input1, weight1));
		products[2] = signExtend(multiplyInt4(input2, weight2));
		products[3] = signExtend(multiplyInt4(input3, weight3));

		productQ.enq(PackedMacProducts{
			laneProducts: products,
			inputIdx: request.inputIdx,
			outputIdx: request.outputIdx,
			width: request.width,
			firstGroup: request.firstGroup,
			lastGroup: request.lastGroup
		});
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Issue two signed INT8 lane multiplications through registered ECP5 MULT18X18Ds
	//------------------------------------------------------------------------------------
	rule processMultiplyInt8 ( quantizedWidth == 8 );
		requestQ.deq;
		let request = requestQ.first;

		QInt8 input0 = unpack(request.inputWord[7:0]);
		QInt8 input1 = unpack(request.inputWord[15:8]);
		QInt8 weight0 = unpack(request.weightWord[7:0]);
		QInt8 weight1 = unpack(request.weightWord[15:8]);
		QInt16 input0Ext = signExtend(input0);
		QInt16 input1Ext = signExtend(input1);
		QInt16 weight0Ext = signExtend(weight0);
		QInt16 weight1Ext = signExtend(weight1);

		dspMultiplier0.put(input0Ext, weight0Ext);
		dspMultiplier1.put(input1Ext, weight1Ext);
		int8MetadataQ.enq(PackedMacMetadata{
			inputIdx: request.inputIdx,
			outputIdx: request.outputIdx,
			firstGroup: request.firstGroup,
			lastGroup: request.lastGroup
		});
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Issue signed INT16 multiplication through one registered ECP5 MULT18X18D
	//------------------------------------------------------------------------------------
	rule processMultiplyInt16 ( quantizedWidth == 16 );
		requestQ.deq;
		let request = requestQ.first;
		QInt16 input0 = unpack(request.inputWord);
		QInt16 weight0 = unpack(request.weightWord);

		dspMultiplier0.put(input0, weight0);
		int16MetadataQ.enq(PackedMacMetadata{
			inputIdx: request.inputIdx,
			outputIdx: request.outputIdx,
			firstGroup: request.firstGroup,
			lastGroup: request.lastGroup
		});
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Align two INT8 DSP results and reduce them through a narrow signed adder
	//------------------------------------------------------------------------------------
	rule receiveMultiplyInt8 ( quantizedWidth == 8 );
		let product0 <- dspMultiplier0.get;
		let product1 <- dspMultiplier1.get;
		int8MetadataQ.deq;
		let metadata = int8MetadataQ.first;

		QInt8Product product0Int8 = truncate(product0);
		QInt8Product product1Int8 = truncate(product1);
		Int#(17) partialSumInt8 =
			signExtend(product0Int8) + signExtend(product1Int8);

		partialQ.enq(PackedMacPartial{
			partialSum: signExtend(partialSumInt8),
			inputIdx: metadata.inputIdx,
			outputIdx: metadata.outputIdx,
			width: 8,
			firstGroup: metadata.firstGroup,
			lastGroup: metadata.lastGroup
		});
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Align the registered INT16 DSP result with its packed-operation metadata
	//------------------------------------------------------------------------------------
	rule receiveMultiplyInt16 ( quantizedWidth == 16 );
		let product <- dspMultiplier0.get;
		int16MetadataQ.deq;
		let metadata = int16MetadataQ.first;
		Vector#(4, Int#(32)) products = replicate(0);
		products[0] = product;

		productQ.enq(PackedMacProducts{
			laneProducts: products,
			inputIdx: metadata.inputIdx,
			outputIdx: metadata.outputIdx,
			width: 16,
			firstGroup: metadata.firstGroup,
			lastGroup: metadata.lastGroup
		});
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Reduce four INT4 or one INT16 product into one partial sum
	//------------------------------------------------------------------------------------
	rule processReduceInt4Int16 ( quantizedWidth != 8 );
		productQ.deq;
		let productData = productQ.first;

		Int#(64) product0 = signExtend(productData.laneProducts[0]);
		Int#(64) product1 = signExtend(productData.laneProducts[1]);
		Int#(64) product2 = signExtend(productData.laneProducts[2]);
		Int#(64) product3 = signExtend(productData.laneProducts[3]);
		Int#(64) sumLow = product0 + product1;
		Int#(64) sumHigh = product2 + product3;
		Int#(64) partialSum = sumLow + sumHigh;

		partialQ.enq(PackedMacPartial{
			partialSum: partialSum,
			inputIdx: productData.inputIdx,
			outputIdx: productData.outputIdx,
			width: productData.width,
			firstGroup: productData.firstGroup,
			lastGroup: productData.lastGroup
		});
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 4]
	// Update one of 64 wide accumulators and requantize a completed dot product
	//------------------------------------------------------------------------------------
	rule processAccumulate;
		partialQ.deq;
		let partial = partialQ.first;

		Int#(64) accumulator = partial.firstGroup
			? 0
			: accumulatorFile.sub(partial.outputIdx);
		Int#(64) nextAccumulator = accumulator + partial.partialSum;

		if ( partial.lastGroup ) begin
			Int#(32) result = 0;
			if ( partial.width == 4 ) begin
				QInt4Accumulator accumulatorInt4 = truncate(nextAccumulator);
				QInt4 value = requantizeInt4(accumulatorInt4, 1, 7, 0);
				result = signExtend(value);
			end else if ( partial.width == 8 ) begin
				QInt8Accumulator accumulatorInt8 = truncate(nextAccumulator);
				QInt8 value = requantizeInt8(accumulatorInt8, 1, 11, 0);
				result = signExtend(value);
			end else begin
				QInt16 value = requantizeInt16(nextAccumulator, 1, 18, 0);
				result = signExtend(value);
			end

			outputQ.enq(tuple3(
				result,
				partial.inputIdx,
				zeroExtend(partial.outputIdx)
			));
		end else begin
			accumulatorFile.upd(partial.outputIdx, nextAccumulator);
		end
	endrule

	method Action setWidth(Bit#(5) width);
		if ( isSupportedQuantizedWidth(width) ) begin
			quantizedWidth <= width;
		end
	endmethod

	method Action putPacked(
		Bit#(16) inputWord,
		Bit#(16) weightWord,
		Bit#(8) inputIdx,
		Bit#(6) outputIdx,
		Bool firstGroup,
		Bool lastGroup
	);
		requestQ.enq(PackedMacRequest{
			inputWord: inputWord,
			weightWord: weightWord,
			inputIdx: inputIdx,
			outputIdx: outputIdx,
			width: quantizedWidth,
			firstGroup: firstGroup,
			lastGroup: lastGroup
		});
	endmethod

	method ActionValue#(Tuple3#(Int#(32), Bit#(8), Bit#(8))) dataOut;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule
