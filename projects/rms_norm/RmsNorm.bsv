package RmsNorm;

import FIFO::*;
import RegFile::*;
import SimpleFloat::*;
import FloatingPoint::*;

// 전체 matrix가 아닌 normalization vector 하나를 처리한다.
interface RmsNormIfc#(numeric type maxCols);
    method Action startRow(UInt#(32) length, Float meanScale, Float eps);
    method Action put(Float value);
    method ActionValue#(Float) get;
endinterface

// RMSNorm 연산 순서를 나타낸다.
typedef enum {
    RmsIdle,
    RmsLoadInput,
    RmsIssueSquare,
    RmsWaitSquare,
    RmsWaitSum,
    RmsWaitMean,
    RmsWaitEpsilon,
    RmsWaitRsqrtY2,
    RmsWaitRsqrtXY2,
    RmsWaitRsqrtHalfXY2,
    RmsWaitRsqrtCorrection,
    RmsWaitRsqrtEstimate,
    RmsIssueNormalize,
    RmsWaitNormalize,
    RmsDrainOutput
} RmsState deriving (Bits, Eq, FShow);

module mkRmsNorm(RmsNormIfc#(maxCols))
    provisos (Add#(TLog#(maxCols), addrPadding, 32));

    // 현재 normalization vector를 저장한다.
    RegFile#(Bit#(TLog#(maxCols)), Float) rowBuffer <- mkRegFileFull;
    FIFO#(Float) outputQ <- mkFIFO;

    // SimpleFloat multiplier와 adder를 하나씩 공유한다.
    FloatTwoOp fmult <- mkFloatMult;
    FloatTwoOp fadd <- mkFloatAdd;

    Reg#(RmsState) rmsState <- mkReg(RmsIdle);

    // 현재 vector 설정값
    Reg#(UInt#(32)) rmsLength <- mkReg(0);
    Reg#(Float) rmsMeanScale <- mkReg(0);
    Reg#(Float) rmsEps <- mkReg(0);

    // 입력과 계산 위치
    Reg#(UInt#(32)) inputIndex <- mkReg(0);
    Reg#(UInt#(32)) sumIndex <- mkReg(0);
    Reg#(UInt#(32)) normalizeIndex <- mkReg(0);

    // RMSNorm 중간값
    Reg#(Float) sumSq <- mkReg(0);
    Reg#(Float) meanPlusEps <- mkReg(0);
    Reg#(Float) invRms <- mkReg(0);
    Reg#(Bit#(1)) rsqrtIteration <- mkReg(0);

    // 외부가 아직 가져가지 않은 결과 수
    Reg#(UInt#(32)) outputsRemaining <- mkReg(0);

    // x[i]^2 연산을 요청한다.
    rule issueSquare (rmsState == RmsIssueSquare);
        Bit#(TLog#(maxCols)) addr = truncate(pack(sumIndex));
        Float x = rowBuffer.sub(addr);

        fmult.put(x, x);
        rmsState <= RmsWaitSquare;
    endrule

    // x[i]^2 결과를 받아 누적 덧셈을 요청한다.
    rule receiveSquare (rmsState == RmsWaitSquare);
        let square <- fmult.get;

        fadd.put(sumSq, square);
        rmsState <= RmsWaitSum;
    endrule

    // 제곱합을 갱신하고 다음 원소 또는 평균 계산으로 이동한다.
    rule receiveAccumulatedSum (rmsState == RmsWaitSum);
        let newSum <- fadd.get;

        sumSq <= newSum;

        if (sumIndex + 1 == rmsLength) begin
            // meanSq = sumSq * (1 / length)
            fmult.put(newSum, rmsMeanScale);
            rmsState <= RmsWaitMean;
        end
        else begin
            sumIndex <= sumIndex + 1;
            rmsState <= RmsIssueSquare;
        end
    endrule

    // meanSq에 epsilon을 더한다.
    rule receiveMean (rmsState == RmsWaitMean);
        let meanSq <- fmult.get;

        fadd.put(meanSq, rmsEps);
        rmsState <= RmsWaitEpsilon;
    endrule

    // meanSq + eps를 받아 inverse square root 계산을 시작한다.
    rule receiveMeanPlusEpsilon (rmsState == RmsWaitEpsilon);
        let x <- fadd.get;

        meanPlusEps <= x;

        Bit#(32) xBits = pack(x);

        // Fast inverse-square-root 초기 근사값
        Bit#(32) estimateBits = 32'h5f3759df - (xBits >> 1);
        Float initialEstimate = unpack(estimateBits);

        invRms <= initialEstimate;
        rsqrtIteration <= 0;

        // Newton-Raphson의 y^2 계산
        fmult.put(initialEstimate, initialEstimate);
        rmsState <= RmsWaitRsqrtY2;
    endrule

    // y^2 결과를 받아 x*y^2를 요청한다.
    rule receiveRsqrtY2 (rmsState == RmsWaitRsqrtY2);
        let y2 <- fmult.get;

        fmult.put(meanPlusEps, y2);
        rmsState <= RmsWaitRsqrtXY2;
    endrule

    // x*y^2 결과에 0.5를 곱한다.
    rule receiveRsqrtXY2 (rmsState == RmsWaitRsqrtXY2);
        let xy2 <- fmult.get;

        Float half = unpack(32'h3f000000); // 0.5

        fmult.put(xy2, half);
        rmsState <= RmsWaitRsqrtHalfXY2;
    endrule

    // 1.5 - 0.5*x*y^2를 요청한다.
    rule receiveRsqrtHalfXY2 (rmsState == RmsWaitRsqrtHalfXY2);
        let halfXY2 <- fmult.get;

        // sign bit를 반전하여 음수로 만든다.
        Bit#(32) negativeBits = pack(halfXY2) ^ 32'h80000000;
        Float negativeHalfXY2 = unpack(negativeBits);
        Float onePointFive = unpack(32'h3fc00000); // 1.5

        fadd.put(onePointFive, negativeHalfXY2);
        rmsState <= RmsWaitRsqrtCorrection;
    endrule

    // 현재 inverse RMS 추정값에 correction을 곱한다.
    rule receiveRsqrtCorrection (rmsState == RmsWaitRsqrtCorrection);
        let correction <- fadd.get;

        fmult.put(invRms, correction);
        rmsState <= RmsWaitRsqrtEstimate;
    endrule

    // 새로운 inverse RMS 추정값을 받는다.
    rule receiveRsqrtEstimate (rmsState == RmsWaitRsqrtEstimate);
        let newEstimate <- fmult.get;

        invRms <= newEstimate;

        // Newton-Raphson을 두 번 수행한다.
        if (rsqrtIteration == 1) begin
            normalizeIndex <= 0;
            rmsState <= RmsIssueNormalize;
        end
        else begin
            rsqrtIteration <= rsqrtIteration + 1;
            fmult.put(newEstimate, newEstimate);
            rmsState <= RmsWaitRsqrtY2;
        end
    endrule

    // x[i]*invRms 연산을 요청한다.
    rule issueNormalizedValue (rmsState == RmsIssueNormalize);
        Bit#(TLog#(maxCols)) addr = truncate(pack(normalizeIndex));
        Float x = rowBuffer.sub(addr);

        fmult.put(x, invRms);
        rmsState <= RmsWaitNormalize;
    endrule

    // 정규화 결과를 출력 FIFO에 넣는다.
    rule receiveNormalizedValue (rmsState == RmsWaitNormalize);
        let value <- fmult.get;

        outputQ.enq(value);

        if (normalizeIndex + 1 == rmsLength) begin
            rmsState <= RmsDrainOutput;
        end
        else begin
            normalizeIndex <= normalizeIndex + 1;
            rmsState <= RmsIssueNormalize;
        end
    endrule

    // 마지막 결과까지 외부가 소비하면 Idle로 돌아간다.
    rule finishOutputDrain (
        rmsState == RmsDrainOutput &&
        outputsRemaining == 0
    );
        rmsState <= RmsIdle;
    endrule

    // 새로운 normalization vector를 시작한다.
    method Action startRow(UInt#(32) length, Float meanScale, Float eps)
        if (rmsState == RmsIdle);

        if (
            length > 0 &&
            length <= fromInteger(valueOf(maxCols))
        ) begin
            rmsLength <= length;
            rmsMeanScale <= meanScale;
            rmsEps <= eps;

            inputIndex <= 0;
            sumIndex <= 0;
            normalizeIndex <= 0;

            sumSq <= 0;
            meanPlusEps <= 0;
            invRms <= 0;
            rsqrtIteration <= 0;

            outputsRemaining <= length;
            rmsState <= RmsLoadInput;
        end
    endmethod

    // 현재 vector의 입력 원소를 저장한다.
    method Action put(Float value)
        if (
            rmsState == RmsLoadInput &&
            inputIndex < rmsLength
        );

        Bit#(TLog#(maxCols)) addr = truncate(pack(inputIndex));
        rowBuffer.upd(addr, value);

        if (inputIndex + 1 == rmsLength) begin
            inputIndex <= 0;
            sumIndex <= 0;
            sumSq <= 0;
            rmsState <= RmsIssueSquare;
        end
        else begin
            inputIndex <= inputIndex + 1;
        end
    endmethod

    // 결과 하나를 반환하고 미소비 결과 수를 감소시킨다.
    method ActionValue#(Float) get
        if (
            rmsState != RmsIdle &&
            outputsRemaining > 0
        );

        let result = outputQ.first;
        outputQ.deq;

        outputsRemaining <= outputsRemaining - 1;

        return result;
    endmethod

endmodule

endpackage: RmsNorm
