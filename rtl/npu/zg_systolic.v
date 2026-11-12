// ZAGROS-1  ZG-NPU systolic array (N x N output-stationary) with built-in input skew.
// Each cycle with in_valid=1 feeds one K step: a_vec = column k of A (A[0..N-1][k]), b_vec = row k of B (B[k][0..N-1]).
// Inside, row i of a_vec is delayed i cycles and column j of b_vec is delayed j cycles, so PE(i,j) sees
// A[i][k] and B[k][j] together at cycle k+i+j. The last product lands 2N-2 cycles after the last K step;
// `busy` stays high until every accumulator holds its final value.
// acc_flat holds C[i][j] at bits [(i*N+j)*AW +: AW].
// All internal arrays are flattened vectors (Yosys-friendly, no multi-dimensional wire arrays).
`default_nettype none

module zg_systolic #(
    parameter N  = 8,
    parameter AW = 32
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 en,
    input  wire                 clr,        // clear all accumulators (assert before the first K step)
    input  wire                 in_valid,
    input  wire [N*8-1:0]       a_vec,      // a_vec[i*8 +: 8] = A[i][k]
    input  wire [N*8-1:0]       b_vec,      // b_vec[j*8 +: 8] = B[k][j]
    output wire [N*N*AW-1:0]    acc_flat,
    output wire                 busy
);
    // skewed edge inputs
    wire [N*8-1:0] a_sk;
    wire [N-1:0]   v_sk;
    wire [N*8-1:0] b_sk;

    // horizontal links: PE(i,j) left input = ah[(i*(N+1)+j)], right output = ah[(i*(N+1)+j+1)]
    // (the last column's a/v outputs and the last row's b outputs leave the array unused: expected)
    /* verilator lint_off UNUSEDSIGNAL */
    wire [N*(N+1)*8-1:0] ah;
    wire [N*(N+1)-1:0]   vh;
    // vertical links: PE(i,j) top input = bv[(i*N+j)], bottom output = bv[((i+1)*N+j)]
    wire [(N+1)*N*8-1:0] bv;
    /* verilator lint_on UNUSEDSIGNAL */

    genvar i, j;
    generate
        // ---------------- input skew: lane i delayed by i cycles ----------------
        for (i = 0; i < N; i = i + 1) begin : g_skew
            wire [7:0] a_in_i = in_valid ? a_vec[i*8 +: 8] : 8'd0;
            wire [7:0] b_in_i = in_valid ? b_vec[i*8 +: 8] : 8'd0;
            if (i == 0) begin : g_d0
                assign a_sk[0 +: 8] = a_in_i;
                assign b_sk[0 +: 8] = b_in_i;
                assign v_sk[0]      = in_valid;
            end else begin : g_dn
                reg [i*8-1:0] a_sr;
                reg [i*8-1:0] b_sr;
                reg [i-1:0]   v_sr;
                // shift register, newest sample in the low byte; widths exact (lint-clean)
                wire [i*8-1:0] a_nx, b_nx;
                wire [i-1:0]   v_nx;
                if (i == 1) begin : g_one
                    assign a_nx = a_in_i;
                    assign b_nx = b_in_i;
                    assign v_nx = in_valid;
                end else begin : g_many
                    assign a_nx = {a_sr[(i-1)*8-1:0], a_in_i};
                    assign b_nx = {b_sr[(i-1)*8-1:0], b_in_i};
                    assign v_nx = {v_sr[i-2:0], in_valid};
                end
                always @(posedge clk) begin
                    if (!rst_n) begin
                        a_sr <= {(i*8){1'b0}};
                        b_sr <= {(i*8){1'b0}};
                        v_sr <= {i{1'b0}};
                    end else if (en) begin
                        a_sr <= a_nx;
                        b_sr <= b_nx;
                        v_sr <= v_nx;
                    end
                end
                assign a_sk[i*8 +: 8] = a_sr[(i-1)*8 +: 8];
                assign b_sk[i*8 +: 8] = b_sr[(i-1)*8 +: 8];
                assign v_sk[i]        = v_sr[i-1];
            end
        end

        // ---------------- array edges ----------------
        for (i = 0; i < N; i = i + 1) begin : g_edge
            assign ah[(i*(N+1))*8 +: 8] = a_sk[i*8 +: 8];
            assign vh[i*(N+1)]          = v_sk[i];
            assign bv[i*8 +: 8]         = b_sk[i*8 +: 8];   // row 0 top inputs: bv[(0*N+i)]
        end

        // ---------------- PE grid ----------------
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                zg_pe #(.AW(AW)) u_pe (
                    .clk  (clk), .rst_n(rst_n), .en(en), .clr(clr),
                    .a_in (ah[(i*(N+1)+j)*8 +: 8]),
                    .b_in (bv[(i*N+j)*8 +: 8]),
                    .v_in (vh[i*(N+1)+j]),
                    .a_out(ah[(i*(N+1)+j+1)*8 +: 8]),
                    .b_out(bv[((i+1)*N+j)*8 +: 8]),
                    .v_out(vh[i*(N+1)+j+1]),
                    .acc  (acc_flat[(i*N+j)*AW +: AW])
                );
            end
        end
    endgenerate

    // ---------------- busy tracking ----------------
    // last input at cycle K-1 reaches PE(N-1,N-1) at K-1+2(N-1); results are final from cycle K+2N-2.
    localparam CW = $clog2(2*N + 1);
    localparam integer DRAIN_I = 2*N - 1;
    localparam [CW-1:0] DRAIN0 = DRAIN_I[CW-1:0];
    reg [CW-1:0] drain;
    always @(posedge clk) begin
        if (!rst_n)              drain <= {CW{1'b0}};
        else if (en) begin
            if (in_valid)        drain <= DRAIN0;
            else if (drain != 0) drain <= drain - 1'b1;
        end
    end
    assign busy = in_valid | (drain != 0);
endmodule

`default_nettype wire
