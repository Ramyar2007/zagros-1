// ZAGROS-1  ZG-NPU processing element
// Output-stationary: acc += a * b (signed INT8 x INT8 -> INT32). a moves right, b moves down, one register each.
// valid travels with a (horizontally); the array skew guarantees b is aligned with it.
`default_nettype none

module zg_pe #(
    parameter AW = 32                // accumulator width
) (
    input  wire                  clk,
    input  wire                  rst_n,   // synchronous active-low reset
    input  wire                  en,      // global stall: when 0 nothing moves
    input  wire                  clr,     // clear accumulator (takes priority over accumulate)
    input  wire signed [7:0]     a_in,
    input  wire signed [7:0]     b_in,
    input  wire                  v_in,
    output reg  signed [7:0]     a_out,
    output reg  signed [7:0]     b_out,
    output reg                   v_out,
    output reg  signed [AW-1:0]  acc
);
    wire signed [15:0] prod = a_in * b_in;

    always @(posedge clk) begin
        if (!rst_n) begin
            a_out <= 8'sd0;
            b_out <= 8'sd0;
            v_out <= 1'b0;
            acc   <= {AW{1'b0}};
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
            v_out <= v_in;
            if (clr)
                acc <= {AW{1'b0}};
            else if (v_in)
                acc <= acc + {{(AW-16){prod[15]}}, prod};
        end
    end
endmodule

`default_nettype wire
