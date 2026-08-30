package TbSelectiveSSMMatrix;

import RegFile::*;
import Vector::*;
import SelectiveSSM::*;

module mkTbSelectiveSSMMatrix(Empty);
    SelectiveSSMIfc dut <- mkSelectiveSSM;
    RegFile#(Bit#(4), Bit#(32)) inputData <- mkRegFileLoad("input.txt", 0, 15);
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

    rule printResult (started && dut.resultValid);
        StateMatrix state = dut.newState;
        ChannelVector y = dut.y;

        $display("calculated_new_state_q16 %0d %0d %0d %0d",
            state[0][0], state[0][1], state[1][0], state[1][1]);
        $display("calculated_y_q16 %0d %0d", y[0], y[1]);
        $finish(0);
    endrule
endmodule

endpackage
