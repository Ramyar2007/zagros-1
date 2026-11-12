// ZAGROS-1  ZG-NPU: register file + DMA + 8x8 systolic array + requantizer.
//
// ZG-BUS (used for both the slave register port and the DMA master port)
//   request : req, we, addr, wdata, be  -> accepted in the cycle gnt=1 (master holds the request until then)
//   response: reads return rdata with rvalid=1 exactly one cycle after the grant; writes complete at the grant.
//
// Operation (one 8x8 output tile):  C = requant( A[8 x K] * B[K x 8] (+ bias) )
//   A row-major:  A[i][k] at A_ADDR + i*A_STRIDE + k      (bytes, int8)
//   B row-major:  B[k][j] at B_ADDR + k*B_STRIDE + j      (bytes, int8)
//   C row-major:  C[i][j] at C_ADDR + i*C_STRIDE + j      (int8)   or + 4*j (int32 when RAW_OUT)
//   bias (opt.):  bias[j] at BIAS_ADDR + 4*j              (int32, added before scaling)
//   All addresses/strides must be multiples of 4 and K a multiple of 4 in [4, KMAX] (else STATUS.ERR).
//   Larger K: run chunks with ACC_KEEP=1 on every chunk after the first and NO_STORE=1 on every chunk but the last.
// Requant per element:  v = acc + bias[j];  y = round_shift(v * MULT, SHIFT) + ZP;  clamp to [RELU ? ZP : -128, 127]
//   round_shift(x, s) = s == 0 ? x : (x + 2^(s-1)) >>> s      (arithmetic, round half up)
//
// Registers (byte offset): 00 CTRL  04 STATUS  08 A_ADDR  0C A_STRIDE  10 B_ADDR  14 B_STRIDE  18 C_ADDR  1C C_STRIDE
//   20 K  24 MULT  28 SHIFT  2C ZP  30 BIAS_ADDR  34 CYCLES (last op)  38 ID = 0x5A474E50 ("ZGNP")
// CTRL: [0] START (self-clearing)  [1] ACC_KEEP  [2] RELU  [3] IRQ_EN  [4] BIAS_EN  [5] RAW_OUT  [6] NO_STORE
// STATUS: [0] BUSY  [1] DONE (write 1 to clear; irq = DONE & IRQ_EN)  [2] ERR (write 1 to clear)
`default_nettype none

module zg_npu #(
    parameter N    = 8,          // array size (this controller assumes N == 8: two 32-bit words per row of bytes)
    parameter KMAX = 32
) (
    input  wire        clk,
    input  wire        rst_n,
    // slave register port
    input  wire        s_req,
    input  wire        s_we,
    input  wire [5:0]  s_addr,      // byte offset [5:0]
    input  wire [31:0] s_wdata,
    output wire        s_gnt,
    output reg  [31:0] s_rdata,
    output reg         s_rvalid,
    // DMA master port
    output reg         m_req,
    output reg         m_we,
    output reg  [31:0] m_addr,
    output reg  [31:0] m_wdata,
    output reg  [3:0]  m_be,
    input  wire        m_gnt,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,
    output wire        irq
);
    localparam AW = 32;
    localparam KW = $clog2(KMAX + 1);

    // ------------------------------------------------------------------ registers
    reg        r_keep, r_relu, r_irqen, r_bias, r_raw, r_nostore;
    reg        st_busy, st_done, st_err;
    reg [31:0] r_a_addr, r_a_stride, r_b_addr, r_b_stride, r_c_addr, r_c_stride, r_bias_addr;
    reg [KW-1:0] r_k;
    reg [31:0] r_mult;
    reg [5:0]  r_shift;
    reg [7:0]  r_zp;
    reg [31:0] r_cycles;
    reg        start_pulse;

    assign s_gnt = s_req;            // registers always accept in one cycle
    assign irq   = st_done & r_irqen;

    wire cfg_ok = (r_a_addr[1:0] == 2'b0) && (r_a_stride[1:0] == 2'b0) && (r_b_addr[1:0] == 2'b0) &&
                  (r_b_stride[1:0] == 2'b0) && (r_c_addr[1:0] == 2'b0) && (r_c_stride[1:0] == 2'b0) &&
                  (r_bias_addr[1:0] == 2'b0) && (r_k[1:0] == 2'b0) && (r_k != 0) && (r_k <= KMAX);

    always @(posedge clk) begin
        if (!rst_n) begin
            {r_keep, r_relu, r_irqen, r_bias, r_raw, r_nostore} <= 6'b0;
            r_a_addr <= 0; r_a_stride <= 0; r_b_addr <= 0; r_b_stride <= 0;
            r_c_addr <= 0; r_c_stride <= 0; r_bias_addr <= 0;
            r_k <= 0; r_mult <= 32'd1; r_shift <= 0; r_zp <= 0;
            start_pulse <= 1'b0;
            s_rvalid <= 1'b0; s_rdata <= 32'd0;
        end else begin
            start_pulse <= 1'b0;
            s_rvalid    <= s_req & ~s_we;
            if (s_req && s_we && !st_busy) begin
                case (s_addr[5:2])
                    4'h0: begin
                        {r_nostore, r_raw, r_bias, r_irqen, r_relu, r_keep} <= s_wdata[6:1];
                        start_pulse <= s_wdata[0];
                    end
                    4'h2: r_a_addr    <= s_wdata;
                    4'h3: r_a_stride  <= s_wdata;
                    4'h4: r_b_addr    <= s_wdata;
                    4'h5: r_b_stride  <= s_wdata;
                    4'h6: r_c_addr    <= s_wdata;
                    4'h7: r_c_stride  <= s_wdata;
                    4'h8: r_k         <= s_wdata[KW-1:0];
                    4'h9: r_mult      <= s_wdata;
                    4'hA: r_shift     <= s_wdata[5:0];
                    4'hB: r_zp        <= s_wdata[7:0];
                    4'hC: r_bias_addr <= s_wdata;
                    default: ;
                endcase
            end
            if (s_req && !s_we) begin
                case (s_addr[5:2])
                    4'h0: s_rdata <= {25'd0, r_nostore, r_raw, r_bias, r_irqen, r_relu, r_keep, 1'b0};
                    4'h1: s_rdata <= {29'd0, st_err, st_done, st_busy};
                    4'h2: s_rdata <= r_a_addr;
                    4'h3: s_rdata <= r_a_stride;
                    4'h4: s_rdata <= r_b_addr;
                    4'h5: s_rdata <= r_b_stride;
                    4'h6: s_rdata <= r_c_addr;
                    4'h7: s_rdata <= r_c_stride;
                    4'h8: s_rdata <= {{(32-KW){1'b0}}, r_k};
                    4'h9: s_rdata <= r_mult;
                    4'hA: s_rdata <= {26'd0, r_shift};
                    4'hB: s_rdata <= {24'd0, r_zp};
                    4'hC: s_rdata <= r_bias_addr;
                    4'hD: s_rdata <= r_cycles;
                    4'hE: s_rdata <= 32'h5A47_4E50;
                    default: s_rdata <= 32'd0;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------ local buffers
    // abuf[k] = column k of A (byte lane i = A[i][k]);  bbuf[k] = row k of B (byte lane j = B[k][j])
    reg [N*8-1:0]  abuf [0:KMAX-1];
    reg [N*8-1:0]  bbuf [0:KMAX-1];
    reg [AW-1:0]   bias [0:N-1];

    // ------------------------------------------------------------------ systolic array
    reg            arr_clr, arr_valid;
    reg  [N*8-1:0] arr_a, arr_b;
    wire [N*N*AW-1:0] acc_flat;
    wire           arr_busy;

    zg_systolic #(.N(N), .AW(AW)) u_arr (
        .clk(clk), .rst_n(rst_n), .en(1'b1), .clr(arr_clr), .in_valid(arr_valid),
        .a_vec(arr_a), .b_vec(arr_b), .acc_flat(acc_flat), .busy(arr_busy)
    );

    // ------------------------------------------------------------------ requantizer (one element per cycle, 2-stage)
    reg  [2:0] ri, rj;                                   // element being requantized
    wire signed [AW-1:0] acc_sel  = acc_flat[(ri*N + rj)*AW +: AW];
    wire signed [AW-1:0] bias_sel = r_bias ? bias[rj] : {AW{1'b0}};
    wire signed [AW-1:0] v_sum    = acc_sel + bias_sel;
    reg  signed [63:0]   q_prod;                         // stage 1 register
    wire signed [63:0]   q_rnd    = (r_shift == 0) ? q_prod : (q_prod + (64'sd1 <<< (r_shift - 1'b1)));
    wire signed [63:0]   q_sh     = q_rnd >>> r_shift;
    wire signed [63:0]   q_zp     = q_sh + {{56{r_zp[7]}}, r_zp};
    wire signed [63:0]   q_lo     = r_relu ? {{56{r_zp[7]}}, r_zp} : -64'sd128;
    wire        [7:0]    q_out    = (q_zp > 64'sd127) ? 8'h7F : (q_zp < q_lo) ? q_lo[7:0] : q_zp[7:0];

    // ------------------------------------------------------------------ main FSM
    localparam S_IDLE = 4'd0, S_BIAS = 4'd1, S_LDA = 4'd2, S_LDB = 4'd3, S_CLR = 4'd4, S_RUN = 4'd5,
               S_DRAIN = 4'd6, S_REQ = 4'd7 /* Q2 */, S_STORE = 4'd8 /* Q1 */, S_WR = 4'd9, S_DONE = 4'd10;
    reg [3:0]  state;
    reg [3:0]  row;                 // row index for A loads / C stores (0..N-1)
    reg [KW-1:0] kk;                // k index (word granularity for A, row for B)
    reg        half;                // which 32-bit half of an 8-byte row
    reg        wait_r;              // read issued, waiting for rvalid
    reg [3:0]  bi;                  // bias index
    reg [31:0] wbuf;                // packed output bytes (int8 mode)

    integer x;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; st_busy <= 1'b0; st_done <= 1'b0; st_err <= 1'b0; r_cycles <= 0;
            m_req <= 1'b0; m_we <= 1'b0; m_addr <= 0; m_wdata <= 0; m_be <= 4'h0;
            arr_clr <= 1'b0; arr_valid <= 1'b0; arr_a <= 0; arr_b <= 0;
            row <= 0; kk <= 0; half <= 1'b0; wait_r <= 1'b0; bi <= 0; wbuf <= 0;
            ri <= 0; rj <= 0; q_prod <= 0;
            for (x = 0; x < N; x = x + 1) bias[x] <= 0;
        end else begin
            arr_clr   <= 1'b0;
            arr_valid <= 1'b0;
            if (st_busy) r_cycles <= r_cycles + 1'b1;
            // status write-1-to-clear
            if (s_req && s_we && s_addr[5:2] == 4'h1) begin
                if (s_wdata[1]) st_done <= 1'b0;
                if (s_wdata[2]) st_err  <= 1'b0;
            end
            // DMA request accepted -> drop it (the state logic below may raise the next one)
            if (m_req && m_gnt) m_req <= 1'b0;

            case (state)
            S_IDLE: if (start_pulse) begin
                if (!cfg_ok) begin
                    st_err <= 1'b1;
                end else begin
                    st_busy <= 1'b1; st_done <= 1'b0; r_cycles <= 0;
                    row <= 0; kk <= 0; half <= 1'b0; wait_r <= 1'b0; bi <= 0;
                    state <= r_bias ? S_BIAS : S_LDA;
                end
            end

            // ---- bias: N words
            S_BIAS: begin
                if (!wait_r && !m_req) begin
                    m_req <= 1'b1; m_we <= 1'b0; m_be <= 4'hF; m_addr <= r_bias_addr + {bi, 2'b00}; wait_r <= 1'b1;
                end else if (wait_r && m_rvalid) begin
                    bias[bi[2:0]] <= m_rdata; wait_r <= 1'b0;
                    if (bi == N - 1) begin bi <= 0; state <= S_LDA; end
                    else bi <= bi + 1'b1;
                end
            end

            // ---- A: for each row i, K/4 words; word w holds A[i][4w..4w+3] -> abuf[4w+b] lane i
            S_LDA: begin
                if (!wait_r && !m_req) begin
                    m_req <= 1'b1; m_we <= 1'b0; m_be <= 4'hF;
                    m_addr <= r_a_addr + row * r_a_stride + {kk, 2'b00}; wait_r <= 1'b1;
                end else if (wait_r && m_rvalid) begin
                    wait_r <= 1'b0;
                    for (x = 0; x < 4; x = x + 1)
                        abuf[{kk, 2'b00} + x][row*8 +: 8] <= m_rdata[x*8 +: 8];
                    if ({kk, 2'b00} + 3'd4 >= r_k) begin
                        kk <= 0;
                        if (row == N - 1) begin row <= 0; state <= S_LDB; end
                        else row <= row + 1'b1;
                    end else kk <= kk + 1'b1;
                end
            end

            // ---- B: for each k, two words (bytes 0-3, 4-7 of row k)
            S_LDB: begin
                if (!wait_r && !m_req) begin
                    m_req <= 1'b1; m_we <= 1'b0; m_be <= 4'hF;
                    m_addr <= r_b_addr + kk * r_b_stride + {half, 2'b00}; wait_r <= 1'b1;
                end else if (wait_r && m_rvalid) begin
                    wait_r <= 1'b0;
                    bbuf[kk][half*32 +: 32] <= m_rdata;
                    half <= ~half;
                    if (half) begin
                        if (kk + 1'b1 == r_k) begin kk <= 0; state <= S_CLR; end
                        else kk <= kk + 1'b1;
                    end
                end
            end

            S_CLR: begin
                if (!r_keep) arr_clr <= 1'b1;
                kk <= 0;
                state <= S_RUN;
            end

            // ---- stream K steps into the array, one per cycle
            S_RUN: begin
                arr_valid <= 1'b1;
                arr_a <= abuf[kk];
                arr_b <= bbuf[kk];
                if (kk + 1'b1 == r_k) begin kk <= 0; state <= S_DRAIN; end
                else kk <= kk + 1'b1;
            end

            S_DRAIN: if (!arr_busy && !arr_valid) begin
                if (r_nostore) state <= S_DONE;
                else begin
                    ri <= 0; rj <= 0; state <= S_STORE;
                end
            end

            // ---- requantize / pack / write back: Q1 multiply -> Q2 round/clamp/pack -> WR (bus write)
            S_STORE: begin                       // Q1
                q_prod <= v_sum * $signed({{32{r_mult[31]}}, r_mult});
                state  <= S_REQ;
            end

            S_REQ: begin                         // Q2
                if (r_raw) begin
                    m_wdata <= v_sum;
                    m_addr  <= r_c_addr + ri * r_c_stride + {rj, 2'b00};
                    m_be <= 4'hF; m_we <= 1'b1; m_req <= 1'b1;
                    state <= S_WR;
                end else begin
                    wbuf[rj[1:0]*8 +: 8] <= q_out;
                    if (rj[1:0] == 2'd3) begin
                        m_wdata <= {q_out, wbuf[23:0]};
                        m_addr  <= r_c_addr + ri * r_c_stride + {rj[2], 2'b00};
                        m_be <= 4'hF; m_we <= 1'b1; m_req <= 1'b1;
                        state <= S_WR;
                    end else begin
                        {ri, rj} <= {ri, rj} + 1'b1;
                        state <= S_STORE;
                    end
                end
            end

            S_WR: if (m_req && m_gnt) begin
                m_we <= 1'b0;
                if (ri == N - 1 && rj == N - 1) state <= S_DONE;
                else begin
                    {ri, rj} <= {ri, rj} + 1'b1;
                    state <= S_STORE;
                end
            end

            S_DONE: begin
                st_busy <= 1'b0; st_done <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
