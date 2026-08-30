package TbSelectiveSSM;

import Vector::*;
import RegFile::*;
import SelectiveSSM::*;

function Bool withinTolerance(Q16 actual, Q16 expected, Q16 tolerance);
    Q16 difference = actual - expected;
    return difference <= tolerance && difference >= -tolerance;
endfunction

(* synthesize *)
module mkTbSelectiveSSM(Empty);
    SelectiveSSMIfc dut <- mkSelectiveSSM;
    RegFile#(Bit#(4), Bit#(32)) inputData <-
        mkRegFileLoad("/home/cplcck/mamba-ssm-bsv/vectors/input.txt", 0, 15);
    Reg#(Bit#(5)) loadIndex <- mkReg(0);
    Reg#(Bool) started <- mkReg(False);

    Reg#(ChannelVector) xReg <- mkReg(replicate(0));
    Reg#(ChannelVector) dtReg <- mkReg(replicate(0));
    Reg#(StateMatrix) aReg <- mkReg(replicate(replicate(0)));
    Reg#(StateVector) bReg <- mkReg(replicate(0));
    Reg#(StateVector) cReg <- mkReg(replicate(0));
    Reg#(StateMatrix) stateInputReg <- mkReg(replicate(replicate(0)));

    rule loadInput (!started && loadIndex < 16);
        Q16 value = unpack(inputData.sub(truncate(loadIndex)));

        case (loadIndex)
            0: begin
                StateMatrix next = stateInputReg;
                next[0][0] = value;
                stateInputReg <= next;
            end
            1: begin
                StateMatrix next = stateInputReg;
                next[0][1] = value;
                stateInputReg <= next;
            end
            2: begin
                StateMatrix next = stateInputReg;
                next[1][0] = value;
                stateInputReg <= next;
            end
            3: begin
                StateMatrix next = stateInputReg;
                next[1][1] = value;
                stateInputReg <= next;
            end
            4: begin
                ChannelVector next = xReg;
                next[0] = value;
                xReg <= next;
            end
            5: begin
                ChannelVector next = xReg;
                next[1] = value;
                xReg <= next;
            end
            6: begin
                ChannelVector next = dtReg;
                next[0] = value;
                dtReg <= next;
            end
            7: begin
                ChannelVector next = dtReg;
                next[1] = value;
                dtReg <= next;
            end
            8: begin
                StateMatrix next = aReg;
                next[0][0] = value;
                aReg <= next;
            end
            9: begin
                StateMatrix next = aReg;
                next[0][1] = value;
                aReg <= next;
            end
            10: begin
                StateMatrix next = aReg;
                next[1][0] = value;
                aReg <= next;
            end
            11: begin
                StateMatrix next = aReg;
                next[1][1] = value;
                aReg <= next;
            end
            12: begin
                StateVector next = bReg;
                next[0] = value;
                bReg <= next;
            end
            13: begin
                StateVector next = bReg;
                next[1] = value;
                bReg <= next;
            end
            14: begin
                StateVector next = cReg;
                next[0] = value;
                cReg <= next;
            end
            15: begin
                StateVector next = cReg;
                next[1] = value;
                cReg <= next;
            end
        endcase

        loadIndex <= loadIndex + 1;
    endrule

    rule startTest (!started && loadIndex == 16);
        dut.start(xReg, dtReg, aReg, bReg, cReg, stateInputReg);
        started <= True;
    endrule

    rule checkResult (started && dut.resultValid);
        StateMatrix actualState = dut.newState;
        ChannelVector actualY = dut.y;

        StateMatrix expectedState = replicate(replicate(0));
        ChannelVector expectedY = replicate(0);
        expectedState[0][0] = 11815;
        expectedState[0][1] = -20093;
        expectedState[1][0] = 18921;
        expectedState[1][1] = 25992;
        expectedY[0] = -9162;
        expectedY[1] = 28955;

        Q16 tolerance = 128; // 128 / 65536 = 0.001953125
        Bool passed =
            withinTolerance(actualState[0][0], expectedState[0][0], tolerance) &&
            withinTolerance(actualState[0][1], expectedState[0][1], tolerance) &&
            withinTolerance(actualState[1][0], expectedState[1][0], tolerance) &&
            withinTolerance(actualState[1][1], expectedState[1][1], tolerance) &&
            withinTolerance(actualY[0], expectedY[0], tolerance) &&
            withinTolerance(actualY[1], expectedY[1], tolerance);

        $display("calculated_new_state_q16 %0d %0d %0d %0d",
            actualState[0][0], actualState[0][1],
            actualState[1][0], actualState[1][1]);
        $display("calculated_y_q16 %0d %0d", actualY[0], actualY[1]);

        if (passed) begin
            $display("PASS");
            $finish(0);
        end else begin
            $display("FAIL");
            $finish(1);
        end
    endrule
endmodule

endpackage
