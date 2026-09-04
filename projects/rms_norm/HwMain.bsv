import Vector::*;
import FIFO::*;
import Sdram::*;
import FloatingPoint::*;
import RmsNorm::*;

interface HwMainIfc;
    method ActionValue#(Bit#(8)) serial_tx;
    method Action serial_rx(Bit#(8) rx);
endinterface

// 테스트용 HwMain의 실행 단계를 나타낸다.
typedef enum {
    HwLoadInput,
    HwStartRow,
    HwSendRow,
    HwReceiveRow,
    HwFlushOutput,
    HwDone
} HwMainState deriving (Bits, Eq, FShow);

module mkHwMain#(Ulx3sSdramUserIfc mem) (HwMainIfc);

    Reg#(HwMainState) hwState <- mkReg(HwLoadInput);

    // 실행 시간 측정
    Reg#(Bit#(32)) cycles <- mkReg(0);
    Reg#(Bit#(32)) processingStartCycle <- mkReg(0);

    // UART로 받은 FP32 개수
    Reg#(Bit#(5)) inputEnqueued <- mkReg(0);

    // 4x4 테스트 matrix용 FIFO
    FIFO#(Bit#(32)) inputQ <- mkSizedFIFO(16);
    FIFO#(Bit#(32)) outputQ <- mkSizedFIFO(16);

    // 전체 테스트 matrix는 HwMain만 관리한다.
    Reg#(Vector#(4, Vector#(4, Float))) matrixA
        <- mkReg(replicate(replicate(0)));

    Reg#(Vector#(4, Vector#(4, Float))) matrixC
        <- mkReg(replicate(replicate(0)));

    // RMSNorm은 길이 4 이하의 vector를 처리한다.
    RmsNormIfc#(4) rmsNorm <- mkRmsNorm;

    // 입력 matrix 저장 위치
    Reg#(Bit#(5)) loadMatrixCnt <- mkReg(0);
    Reg#(Bit#(2)) loadMatrixRow <- mkReg(0);
    Reg#(Bit#(2)) loadMatrixCol <- mkReg(0);

    // 현재 처리 중인 row와 column
    Reg#(Bit#(2)) processRow <- mkReg(0);
    Reg#(Bit#(2)) sendCol <- mkReg(0);
    Reg#(Bit#(2)) receiveCol <- mkReg(0);

    // 출력 matrix flush 위치
    Reg#(Bit#(2)) flushOutputMatrixRow <- mkReg(0);
    Reg#(Bit#(2)) flushOutputMatrixCol <- mkReg(0);

    // UART serializer와 deserializer
    Reg#(Vector#(4, Bit#(8))) outputSerializer <- mkReg(?);
    Reg#(Bit#(2)) outputSerializerIdx <- mkReg(0);
    Reg#(Vector#(4, Bit#(8))) inputDeserializer <- mkReg(?);
    Reg#(Bit#(2)) inputDeserializerIdx <- mkReg(0);

    rule countCycles;
        cycles <= cycles + 1;
    endrule

    // inputQ의 FP32 값을 matrixA에 저장한다.
    rule loadInputMatrix (
        hwState == HwLoadInput &&
        loadMatrixCnt < 16
    );
        Bit#(32) inputValue = inputQ.first;
        inputQ.deq;

        matrixA[loadMatrixRow][loadMatrixCol] <= unpack(inputValue);
        loadMatrixCnt <= loadMatrixCnt + 1;

        if (loadMatrixCol == 3) begin
            loadMatrixCol <= 0;
            loadMatrixRow <=
                (loadMatrixRow == 3) ? 0 : loadMatrixRow + 1;
        end
        else begin
            loadMatrixCol <= loadMatrixCol + 1;
        end

        if (loadMatrixCnt == 15) begin
            hwState <= HwStartRow;
        end
    endrule

    // 현재 row의 RMSNorm 연산을 시작한다.
    rule startRowNormalization (hwState == HwStartRow);
        Float meanScale = unpack(32'h3e800000); // 0.25
        Float eps = unpack(32'h3727c5ac);       // 1e-5

        rmsNorm.startRow(4, meanScale, eps);

        sendCol <= 0;
        hwState <= HwSendRow;
    endrule

    // 현재 row의 원소를 RMSNorm에 하나씩 전달한다.
    rule sendRowElement (hwState == HwSendRow);
        Float value = matrixA[processRow][sendCol];

        rmsNorm.put(value);

        if (sendCol == 3) begin
            sendCol <= 0;
            hwState <= HwReceiveRow;
        end
        else begin
            sendCol <= sendCol + 1;
        end
    endrule

    // RMSNorm 결과를 matrixC에 저장한다.
    rule receiveNormalizedElement (hwState == HwReceiveRow);
        let value <- rmsNorm.get;

        matrixC[processRow][receiveCol] <= value;

        if (receiveCol == 3) begin
            receiveCol <= 0;

            if (processRow == 3) begin
                hwState <= HwFlushOutput;

                $write(
                    "Acceleration done! %d cycles\n",
                    cycles - processingStartCycle
                );
            end
            else begin
                processRow <= processRow + 1;
                hwState <= HwStartRow;
            end
        end
        else begin
            receiveCol <= receiveCol + 1;
        end
    endrule

    // matrixC를 row-major 순서로 outputQ에 넣는다.
    rule flushOutputMatrix (hwState == HwFlushOutput);
        outputQ.enq(
            pack(matrixC[flushOutputMatrixRow][flushOutputMatrixCol])
        );

        if (flushOutputMatrixCol == 3) begin
            flushOutputMatrixCol <= 0;

            if (flushOutputMatrixRow == 3) begin
                flushOutputMatrixRow <= 0;
                hwState <= HwDone;
            end
            else begin
                flushOutputMatrixRow <= flushOutputMatrixRow + 1;
            end
        end
        else begin
            flushOutputMatrixCol <= flushOutputMatrixCol + 1;
        end
    endrule

    method ActionValue#(Bit#(8)) serial_tx;
        Bit#(8) ret = 0;

        if (outputSerializerIdx == 0) begin
            Vector#(4, Bit#(8)) bytes = unpack(outputQ.first);
            outputQ.deq;

            outputSerializer <= bytes;
            ret = bytes[0];
        end
        else begin
            ret = outputSerializer[outputSerializerIdx];
        end

        outputSerializerIdx <= outputSerializerIdx + 1;

        return ret;
    endmethod

    method Action serial_rx(Bit#(8) data)
        if (
            hwState == HwLoadInput &&
            inputEnqueued < 16
        );

        Vector#(4, Bit#(8)) bytes = inputDeserializer;
        bytes[inputDeserializerIdx] = data;
        inputDeserializer <= bytes;

        if (inputDeserializerIdx == 3) begin
            inputDeserializerIdx <= 0;

            inputQ.enq(pack(bytes));
            inputEnqueued <= inputEnqueued + 1;

            if (inputEnqueued == 15) begin
                processingStartCycle <= cycles;
            end
        end
        else begin
            inputDeserializerIdx <= inputDeserializerIdx + 1;
        end
    endmethod

endmodule