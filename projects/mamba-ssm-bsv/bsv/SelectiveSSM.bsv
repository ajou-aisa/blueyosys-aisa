package SelectiveSSM;

import Vector::*;

// Q16.16 signed fixed-point value.
typedef Int#(32) Q16;

typedef Vector#(2, Q16) ChannelVector;
typedef Vector#(2, Q16) StateVector;
typedef Vector#(2, StateVector) StateMatrix;

interface SelectiveSSMIfc;
    method Action start(
        ChannelVector x,
        ChannelVector dt,
        StateMatrix a,
        StateVector b,
        StateVector c,
        StateMatrix stateInput
    );
    method Bool resultValid;
    method StateMatrix newState;
    method ChannelVector y;
endinterface

function Q16 multiplyQ16(Q16 lhs, Q16 rhs);
    Int#(64) product = extend(lhs) * extend(rhs);
    return truncate(product >> 16);
endfunction

// softplus(x) around x = 0:
// ln(2) + x/2 + x^2/8 - x^4/192 + x^6/2880
function Q16 softplusQ16(Q16 x);
    Q16 x2 = multiplyQ16(x, x);
    Q16 x4 = multiplyQ16(x2, x2);
    Q16 x6 = multiplyQ16(x4, x2);

    return 45426
        + (x >> 1)
        + multiplyQ16(x2, 8192)
        - multiplyQ16(x4, 341)
        + multiplyQ16(x6, 23);
endfunction

// exp(x) Taylor approximation for the negative range used by this test.
function Q16 expQ16(Q16 x);
    Q16 x2 = multiplyQ16(x, x);
    Q16 x3 = multiplyQ16(x2, x);
    Q16 x4 = multiplyQ16(x3, x);
    Q16 x5 = multiplyQ16(x4, x);
    Q16 x6 = multiplyQ16(x5, x);

    return 65536
        + x
        + multiplyQ16(x2, 32768)
        + multiplyQ16(x3, 10923)
        + multiplyQ16(x4, 2731)
        + multiplyQ16(x5, 546)
        + multiplyQ16(x6, 91);
endfunction

(* synthesize *)
module mkSelectiveSSM(SelectiveSSMIfc);
    Reg#(Bool) busyReg <- mkReg(False);
    Reg#(Bool) validReg <- mkReg(False);

    Reg#(UInt#(1)) channelIndex <- mkReg(0);
    Reg#(UInt#(1)) stateIndex <- mkReg(0);
    Reg#(Q16) accumulator <- mkReg(0);

    Reg#(ChannelVector) xReg <- mkReg(replicate(0));
    Reg#(ChannelVector) dtReg <- mkReg(replicate(0));
    Reg#(StateMatrix) aReg <- mkReg(replicate(replicate(0)));
    Reg#(StateVector) bReg <- mkReg(replicate(0));
    Reg#(StateVector) cReg <- mkReg(replicate(0));
    Reg#(StateMatrix) stateReg <- mkReg(replicate(replicate(0)));
    Reg#(ChannelVector) yReg <- mkReg(replicate(0));

    // One rule firing updates one state element.
    rule updateState (busyReg);
        UInt#(1) channel = channelIndex;
        UInt#(1) state = stateIndex;

        Q16 delta = softplusQ16(dtReg[channel]);
        Q16 xDelta = multiplyQ16(xReg[channel], delta);
        Q16 decay = expQ16(multiplyQ16(delta, aReg[channel][state]));
        Q16 updatedState =
            multiplyQ16(stateReg[channel][state], decay)
            + multiplyQ16(bReg[state], xDelta);
        Q16 updatedAccumulator =
            accumulator + multiplyQ16(updatedState, cReg[state]);

        StateMatrix nextStates = stateReg;
        nextStates[channel][state] = updatedState;
        stateReg <= nextStates;

        if (state == 1) begin
            ChannelVector nextY = yReg;
            nextY[channel] = updatedAccumulator;
            yReg <= nextY;
            accumulator <= 0;
            stateIndex <= 0;

            if (channel == 1) begin
                busyReg <= False;
                validReg <= True;
            end else begin
                channelIndex <= channel + 1;
            end
        end else begin
            accumulator <= updatedAccumulator;
            stateIndex <= state + 1;
        end
    endrule

    method Action start(
        ChannelVector x,
        ChannelVector dt,
        StateMatrix a,
        StateVector b,
        StateVector c,
        StateMatrix stateInput
    ) if (!busyReg);
        xReg <= x;
        dtReg <= dt;
        aReg <= a;
        bReg <= b;
        cReg <= c;
        stateReg <= stateInput;
        yReg <= replicate(0);
        accumulator <= 0;
        channelIndex <= 0;
        stateIndex <= 0;
        validReg <= False;
        busyReg <= True;
    endmethod

    method Bool resultValid;
        return validReg;
    endmethod

    method StateMatrix newState if (validReg);
        return stateReg;
    endmethod

    method ChannelVector y if (validReg);
        return yReg;
    endmethod
endmodule

endpackage
