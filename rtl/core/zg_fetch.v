// ZAGROS-1  ZG-CORE fetch unit: word fetches over ZG-BUS into a halfword FIFO, aligner + RVC expansion.
// ZG-BUS read data returns exactly one cycle after the grant, so with one request per cycle at most one fetch is in
// flight. The request is suppressed in a redirect cycle, so nothing granted ever belongs to an old stream except the
// response arriving in the redirect cycle itself, which the flush ignores.
`default_nettype none

module zg_fetch #(
    parameter [31:0] BOOT = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst_n,
    // instruction bus (read only)
    output wire        i_req,
    output wire [31:0] i_addr,
    input  wire        i_gnt,
    input  wire        i_rvalid,
    input  wire [31:0] i_rdata,
    // redirect from EX (branch, jump, trap, mret)
    input  wire        redirect,
    input  wire [31:0] redirect_pc,
    // to decode
    output wire        o_valid,
    output wire [31:0] o_instr,     // 32-bit instruction (RVC already expanded)
    output wire [31:0] o_pc,
    output wire        o_is_c,      // original instruction was 16-bit
    output wire        o_illegal_c, // illegal compressed encoding
    output wire [31:0] o_raw,       // original bits (for mtval)
    input  wire        o_ready
);
    reg [15:0] fifo [0:7];
    reg [2:0]  rd_p, wr_p;
    reg [3:0]  count;           // halfwords stored
    reg [31:0] head_pc;         // pc of fifo[rd_p]
    reg [31:0] fa;              // next word address to fetch
    reg        skip_half;       // drop the low halfword of the next word (stream starts at pc[1]=1)
    reg        pend;            // a granted fetch returns this cycle (mirrors i_rvalid for this master)

    // room: the word returning now (pend) + the one we request now, 2 halfwords each, minus nothing popped yet
    wire room = (count + (pend ? 4'd2 : 4'd0) + 4'd2) <= 4'd8;
    assign i_req  = rst_n && !redirect && room;
    assign i_addr = fa;

    // aligner
    wire [15:0] h0   = fifo[rd_p];
    wire [15:0] h1   = fifo[rd_p + 3'd1];
    wire        is32 = (h0[1:0] == 2'b11);
    wire        have = is32 ? (count >= 4'd2) : (count != 4'd0);
    wire [31:0] exp_i;
    wire        exp_ill;
    zg_rvc u_rvc (.c(h0), .i(exp_i), .illegal(exp_ill));

    assign o_valid     = have && !redirect;
    assign o_instr     = is32 ? {h1, h0} : exp_i;
    assign o_pc        = head_pc;
    assign o_is_c      = !is32;
    assign o_illegal_c = !is32 && exp_ill;
    assign o_raw       = is32 ? {h1, h0} : {16'd0, h0};

    wire       take = o_valid && o_ready;
    wire [3:0] pop  = take ? (is32 ? 4'd2 : 4'd1) : 4'd0;
    wire [3:0] push = i_rvalid ? (skip_half ? 4'd1 : 4'd2) : 4'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_p <= 3'd0; wr_p <= 3'd0; count <= 4'd0; head_pc <= BOOT;
            fa <= {BOOT[31:2], 2'b00}; skip_half <= BOOT[1]; pend <= 1'b0;
        end else if (redirect) begin
            rd_p <= 3'd0; wr_p <= 3'd0; count <= 4'd0;
            head_pc   <= redirect_pc;
            fa        <= {redirect_pc[31:2], 2'b00};
            skip_half <= redirect_pc[1];
            pend      <= 1'b0;                          // no request was issued this cycle
        end else begin
            pend <= i_req && i_gnt;
            if (i_req && i_gnt) fa <= fa + 32'd4;
            if (i_rvalid) begin
                if (skip_half) begin
                    fifo[wr_p] <= i_rdata[31:16];
                    skip_half  <= 1'b0;
                end else begin
                    fifo[wr_p]        <= i_rdata[15:0];
                    fifo[wr_p + 3'd1] <= i_rdata[31:16];
                end
                wr_p <= wr_p + push[2:0];
            end
            if (take) begin
                rd_p    <= rd_p + pop[2:0];
                head_pc <= head_pc + (is32 ? 32'd4 : 32'd2);
            end
            count <= count + push - pop;
        end
    end
endmodule

`default_nettype wire
