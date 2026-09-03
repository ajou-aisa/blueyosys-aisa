import Clocks :: *;
import Vector::*;
import FIFO::*;
import Uart::*;
import Sdram::*;

import FloatingPoint::*;

interface HwMainIfc;
	method ActionValue#(Bit#(8)) serial_tx;
	method Action serial_rx(Bit#(8) rx);
endinterface

module mkHwMain#(Ulx3sSdramUserIfc mem) (HwMainIfc);
	Clock curclk <- exposeCurrentClock;
	Reset currst <- exposeCurrentReset;

	Reg#(Bit#(32)) cycles <- mkReg(0);
	rule incCyclecount;
		cycles <= cycles + 1;
	endrule

	Reg#(Bit#(32)) processingStartCycle <- mkReg(0);
	Reg#(Bit#(5)) inputEnqueued <- mkReg(0);

	FIFO#(Bit#(32)) inputQ <- mkSizedFIFO(16);
	FIFO#(Bit#(32)) outputQ <- mkSizedFIFO(16);

	Reg#(Vector#(4, Vector#(4, Float))) matrixA
		<- mkReg(replicate(replicate(0)));
	Reg#(Vector#(4, Vector#(4, Float))) matrixC
		<- mkReg(replicate(replicate(0)));

	Reg#(Bool) startOutputFlush <- mkReg(False);
	Reg#(Bit#(5)) loadMatrixCnt <- mkReg(0);
	Reg#(Bit#(2)) loadMatrixCol <- mkReg(0);
	Reg#(Bit#(2)) loadMatrixRow <- mkReg(0);
	rule loadMatrix (loadMatrixCnt < 16 && !startOutputFlush);
		inputQ.deq;
		matrixA[loadMatrixRow][loadMatrixCol] <= unpack(inputQ.first);

		loadMatrixCnt <= loadMatrixCnt + 1;
		loadMatrixCol <= loadMatrixCol + 1;
		if (loadMatrixCol == 3) begin
			loadMatrixRow <= loadMatrixRow + 1;
		end
	endrule

	// C 코드의 변수와 직접 대응되는 레지스터다.
	// rmsRow             : 바깥쪽 row
	// rmsSumCol          : 제곱합을 구하는 첫 번째 i (0~4)
	// rmsSumSq           : sum_sq
	// rmsNewtonIteration : inverse RMS의 Newton 보정 횟수
	// rmsHalfMean        : 0.5 * (mean_sq + eps)
	// rmsInvRms          : inv_rms
	// rmsNormCol         : 결과를 쓰는 두 번째 i
	Reg#(Bit#(2)) rows <- mkReg(4);
	Reg#(Bit#(2)) cols <- mkReg(4);
	
	Reg#(Bit#(2)) rmsRow <- mkReg(0);
	Reg#(Bit#(3)) rmsSumCol <- mkReg(0);
	Reg#(Float) rmsSumSq <- mkReg(0);
	Reg#(Bit#(2)) rmsNewtonIteration <- mkReg(0);
	Reg#(Float) rmsHalfMean <- mkReg(0);
	Reg#(Float) rmsInvRms <- mkReg(0);
	Reg#(Bool) rmsInvValid <- mkReg(False);
	Reg#(Bit#(2)) rmsNormCol <- mkReg(0);

	// 한 rule 안에서 C 코드와 같은 순서로 한 행을 처리한다.
	//   1. sum_sq 계산
	//   2. inv_rms 계산
	//   3. output 계산
	rule processRmsNorm (
		loadMatrixCnt == 16 && !startOutputFlush
	);
		// C:
		// for (i = 0; i < cols; ++i)
		//     sum_sq += x[i] * x[i];
		//
		// 부동소수점 연산을 한 열씩 수행하고 다음 열로 이동한다.
		if (rmsSumCol < 4) begin
			Bit#(2) col = truncate(rmsSumCol);
			Float value = matrixA[rmsRow][col];
			rmsSumSq <= rmsSumSq + value * value;
			rmsSumCol <= rmsSumCol + 1;
		end

		// 네 열의 제곱합을 모두 구했으면 inv_rms를 계산한다.
		// C:
		// mean_sq = sum_sq / cols;
		// inv_rms = 1.0f / sqrt(mean_sq + eps);
		else if (!rmsInvValid) begin
			if (rmsNewtonIteration == 0) begin
				// cols가 4이므로 0.25를 곱해 평균을 구한다.
				// epsilon은 C 호출과 동일한 1e-5로 고정한다.
				Float oneQuarter = unpack(32'h3e800000);
				Float epsilon = unpack(32'h3727c5ac);
				Float oneHalf = unpack(32'h3f000000);
				Float meanSq = rmsSumSq * oneQuarter + epsilon;

				// inverse sqrt의 초기 근삿값을 IEEE-754 비트에서 구한다.
				Bit#(32) estimateBits =
					32'h5f3759df - (pack(meanSq) >> 1);

				rmsHalfMean <= meanSq * oneHalf;
				rmsInvRms <= unpack(estimateBits);
				rmsNewtonIteration <= 1;
			end
			else begin
				// Newton 공식:
				// y = y * (1.5 - 0.5 * x * y * y)
				// 두 번 보정한 뒤 rmsInvRms를 최종값으로 사용한다.
				Float oneAndHalf = unpack(32'h3fc00000);
				Float correction = oneAndHalf -
					rmsHalfMean * rmsInvRms * rmsInvRms;
				rmsInvRms <= rmsInvRms * correction;

				if (rmsNewtonIteration == 2) begin
					rmsInvValid <= True;
				end
				else begin
					rmsNewtonIteration <= rmsNewtonIteration + 1;
				end
			end
		end

		// inv_rms가 준비되면 정규화된 원소를 한 열씩 저장한다.
		// C:
		// for (i = 0; i < cols; ++i)
		//     y[i] = x[i] * inv_rms;
		else begin
			matrixC[rmsRow][rmsNormCol] <=
				matrixA[rmsRow][rmsNormCol] * rmsInvRms;

			if (rmsNormCol == 3) begin
				// 현재 행의 네 결과를 모두 기록했으므로
				// 행 내부 상태를 초기화한다.
				rmsSumCol <= 0;
				rmsSumSq <= 0;
				rmsNewtonIteration <= 0;
				rmsInvValid <= False;
				rmsNormCol <= 0;

				if (rmsRow == 3) begin
					// 네 행을 모두 처리했다. 입력 상태를 초기화하고
					// matrixC를 UART 출력 FIFO로 보내기 시작한다.
					rmsRow <= 0;
					loadMatrixCnt <= 0;
					loadMatrixRow <= 0;
					loadMatrixCol <= 0;
					inputEnqueued <= 0;
					startOutputFlush <= True;
				end
				else begin
					// 다음 행에서 같은 계산을 반복한다.
					rmsRow <= rmsRow + 1;
				end
			end
			else begin
				rmsNormCol <= rmsNormCol + 1;
			end
		end
	endrule

	Reg#(Bit#(2)) flushOutputMatrixRow <- mkReg(0);
	Reg#(Bit#(2)) flushOutputMatrixCol <- mkReg(0);
	// 완성된 matrixC를 row-major 순서로 outputQ에 넣는다.
	rule flushOutput (startOutputFlush && loadMatrixCnt == 0);
		outputQ.enq(pack(
			matrixC[flushOutputMatrixRow][flushOutputMatrixCol]));

		flushOutputMatrixCol <= flushOutputMatrixCol + 1;
		if (flushOutputMatrixCol == 3) begin
			flushOutputMatrixRow <= flushOutputMatrixRow + 1;
			if (flushOutputMatrixRow == 3) begin
				startOutputFlush <= False;
				$write("Acceleration done! %d cycles\n",
					cycles - processingStartCycle);
			end
		end
	endrule

	Reg#(Bit#(2)) outputDeSerializerIdx <- mkReg(0);

	Reg#(Vector#(4, Bit#(8))) inputDeSerializer <- mkReg(?);
	Reg#(Bit#(2)) inputDeSerializerIdx <- mkReg(0);

	method ActionValue#(Bit#(8)) serial_tx;
		Vector#(4, Bit#(8)) serValue = unpack(outputQ.first);
		Bit#(8) ret = serValue[outputDeSerializerIdx];
		if (outputDeSerializerIdx == 3) begin
			outputQ.deq;
		end
		outputDeSerializerIdx <= outputDeSerializerIdx + 1;
		return ret;
	endmethod

	method Action serial_rx(Bit#(8) data)
		if (loadMatrixCnt < 16 && !startOutputFlush);
		Vector#(4, Bit#(8)) desValue = inputDeSerializer;
		desValue[inputDeSerializerIdx] = data;
		inputDeSerializerIdx <= inputDeSerializerIdx + 1;
		inputDeSerializer <= desValue;

		if (inputDeSerializerIdx == 3) begin
			inputQ.enq(pack(desValue));
			inputEnqueued <= inputEnqueued + 1;

			if (inputEnqueued == 15) begin
				processingStartCycle <= cycles;
			end
		end
	endmethod
endmodule
