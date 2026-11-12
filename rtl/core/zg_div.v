// ZAGROS-1  iterative divider for DIV/DIVU/REM/REMU (RISC-V semantics incl. /0 and overflow), 32 + 2 cycles.
`default_nettype none

module zg_div (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,       // pulse with operands valid (ignored while busy)
    input  wire [1:0]  op,          // 00 div, 01 divu, 10 rem, 11 remu  (= funct3[1:0])
    input  wire [31:0] a,           // dividend
    input  wire [31:0] b,           // divisor
    output reg         busy,
    output reg         done,        // one-cycle pulse with result valid
    output reg  [31:0] result
);
    reg [31:0] quo, rem_r, dvs;
    reg [5:0]  cnt;
    reg        neg_q, neg_r, want_rem;

    wire        sgn   = ~op[0];
    wire        a_neg = sgn & a[31];
    wire        b_neg = sgn & b[31];
    wire [31:0] a_abs = a_neg ? -a : a;
    wire [31:0] b_abs = b_neg ? -b : b;

    wire [32:0] trial = {rem_r, quo[31]} - {1'b0, dvs};

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; result <= 32'd0;
            quo <= 0; rem_r <= 0; dvs <= 0; cnt <= 0; neg_q <= 0; neg_r <= 0; want_rem <= 0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                if (b == 32'd0) begin                      // divide by zero: q = -1, r = a
                    result <= op[1] ? a : 32'hFFFF_FFFF;
                    done <= 1'b1;
                end else if (sgn && a == 32'h8000_0000 && b == 32'hFFFF_FFFF) begin   // overflow
                    result <= op[1] ? 32'd0 : 32'h8000_0000;
                    done <= 1'b1;
                end else begin
                    busy <= 1'b1; cnt <= 6'd32;
                    quo <= a_abs; rem_r <= 32'd0; dvs <= b_abs;
                    neg_q <= a_neg ^ b_neg; neg_r <= a_neg; want_rem <= op[1];
                end
            end else if (busy) begin
                if (cnt != 0) begin
                    if (!trial[32]) begin
                        rem_r <= trial[31:0];
                        quo   <= {quo[30:0], 1'b1};
                    end else begin
                        rem_r <= {rem_r[30:0], quo[31]};
                        quo   <= {quo[30:0], 1'b0};
                    end
                    cnt <= cnt - 1'b1;
                end else begin
                    result <= want_rem ? (neg_r ? -rem_r : rem_r) : (neg_q ? -quo : quo);
                    busy <= 1'b0; done <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
