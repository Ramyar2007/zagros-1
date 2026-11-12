// ZAGROS-1  system-on-chip top.
//   masters: core instruction port (CI), core data port (CD), NPU DMA (NP)
//   slaves : I-SRAM 0x0000_0000 (CI, CD), D-SRAM 0x1000_0000 (CD, NP), peripherals 0x4000_0000 (CD), NPU regs 0x5000_0000 (CD)
//   per-slave round-robin arbitration; grant is a pure function of the requests (no combinational loop: every master's
//   request depends only on its own registers). Read data returns one cycle after the grant (ZG-BUS).
//   Unmapped accesses are granted immediately and read as 0.
//   Reset: asynchronous assert, synchronous release through a 2-flop synchroniser.
`default_nettype none

module zg_soc #(
    parameter IWORDS = 2048,       // I-SRAM size in 32-bit words (8 KB)
    parameter DWORDS = 4096,       // D-SRAM size in 32-bit words (16 KB)
    parameter IINIT  = "",
    parameter DINIT  = ""
) (
    input  wire        clk,
    input  wire        rst_n_async,
    output wire        uart_tx,
    input  wire        uart_rx,
    input  wire [15:0] gpio_in,
    output wire [15:0] gpio_out,
    output wire [15:0] gpio_oe,
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n,
    output wire [31:0] post            // firmware status word (also on a debug pin bundle in the pad ring)
);
    // ---------------- reset synchroniser
    reg [1:0] rs;
    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) rs <= 2'b00;
        else rs <= {rs[0], 1'b1};
    end
    wire rst_n = rs[1];

    // ---------------- masters
    wire        ci_req, cd_req, cd_we, np_req, np_we;
    /* verilator lint_off UNUSEDSIGNAL */      // address bits between the region nibble and the memory size are don't-care
    wire [31:0] ci_addr, cd_addr, np_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] cd_wdata, np_wdata;
    wire [3:0]  cd_be, np_be;
    wire        ci_gnt, cd_gnt, np_gnt;
    reg         ci_rv, cd_rv, np_rv;
    wire [31:0] ci_rdata, cd_rdata, np_rdata;
    wire        irq_timer, irq_ext_u, npu_irq;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        rvfi_valid;
    wire [31:0] rvfi_pc;
    /* verilator lint_on UNUSEDSIGNAL */

    zg_core #(.BOOT(32'h0000_0000)) u_core (
        .clk(clk), .rst_n(rst_n),
        .i_req(ci_req), .i_addr(ci_addr), .i_gnt(ci_gnt), .i_rvalid(ci_rv), .i_rdata(ci_rdata),
        .d_req(cd_req), .d_we(cd_we), .d_addr(cd_addr), .d_wdata(cd_wdata), .d_be(cd_be),
        .d_gnt(cd_gnt), .d_rvalid(cd_rv), .d_rdata(cd_rdata),
        .irq_timer(irq_timer), .irq_ext(irq_ext_u | npu_irq),
        .rvfi_valid(rvfi_valid), .rvfi_pc(rvfi_pc)
    );

    // ---------------- address decode
    wire ci_im = ci_addr[31:28] == 4'h0;
    wire cd_im = cd_addr[31:28] == 4'h0;
    wire cd_dm = cd_addr[31:28] == 4'h1;
    wire cd_pr = cd_addr[31:28] == 4'h4;
    wire cd_nr = cd_addr[31:28] == 4'h5;
    wire np_dm = np_addr[31:28] == 4'h1;

    // ---------------- I-SRAM: CI vs CD (round robin)
    wire im_r_ci = ci_req && ci_im;
    wire im_r_cd = cd_req && cd_im;
    reg  im_last;                                   // 1 = CD was granted last
    wire im_g_cd = im_r_cd && (!im_r_ci || !im_last);
    wire im_g_ci = im_r_ci && !im_g_cd;
    wire [31:0] im_rdata;
    zg_sram #(.WORDS(IWORDS), .INIT(IINIT)) u_isram (
        .clk(clk), .en(im_g_ci | im_g_cd), .we(im_g_cd & cd_we),
        .addr(im_g_cd ? cd_addr[$clog2(IWORDS)+1:2] : ci_addr[$clog2(IWORDS)+1:2]),
        .wdata(cd_wdata), .be(cd_be), .rdata(im_rdata)
    );

    // ---------------- D-SRAM: CD vs NP (round robin)
    wire dm_r_cd = cd_req && cd_dm;
    wire dm_r_np = np_req && np_dm;
    reg  dm_last;                                   // 1 = NP was granted last
    wire dm_g_np = dm_r_np && (!dm_r_cd || !dm_last);
    wire dm_g_cd = dm_r_cd && !dm_g_np;
    wire [31:0] dm_rdata;
    zg_sram #(.WORDS(DWORDS), .INIT(DINIT)) u_dsram (
        .clk(clk), .en(dm_g_cd | dm_g_np), .we(dm_g_np ? np_we : cd_we),
        .addr(dm_g_np ? np_addr[$clog2(DWORDS)+1:2] : cd_addr[$clog2(DWORDS)+1:2]),
        .wdata(dm_g_np ? np_wdata : cd_wdata), .be(dm_g_np ? np_be : cd_be), .rdata(dm_rdata)
    );

    always @(posedge clk) begin
        if (!rst_n) begin im_last <= 1'b0; dm_last <= 1'b0; end
        else begin
            if (im_g_ci | im_g_cd) im_last <= im_g_cd;
            if (dm_g_cd | dm_g_np) dm_last <= dm_g_np;
        end
    end

    // ---------------- peripherals + NPU registers (CD only, always granted)
    wire [31:0] pr_rdata;
    zg_periph u_periph (
        .clk(clk), .rst_n(rst_n), .req(cd_req && cd_pr), .we(cd_we), .addr(cd_addr[15:0]), .wdata(cd_wdata), .be(cd_be),
        .rdata(pr_rdata),
        .uart_tx(uart_tx), .uart_rx(uart_rx), .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .irq_timer(irq_timer), .irq_ext(irq_ext_u), .post(post)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire        nr_gnt;
    wire        nr_rvalid;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] nr_rdata;
    zg_npu u_npu (
        .clk(clk), .rst_n(rst_n),
        .s_req(cd_req && cd_nr), .s_we(cd_we), .s_addr(cd_addr[5:0]), .s_wdata(cd_wdata),
        .s_gnt(nr_gnt), .s_rdata(nr_rdata), .s_rvalid(nr_rvalid),
        .m_req(np_req), .m_we(np_we), .m_addr(np_addr), .m_wdata(np_wdata), .m_be(np_be),
        .m_gnt(np_gnt), .m_rdata(np_rdata), .m_rvalid(np_rv), .irq(npu_irq)
    );

    // ---------------- grants
    assign ci_gnt = ci_im ? im_g_ci : 1'b1;
    assign cd_gnt = cd_im ? im_g_cd : cd_dm ? dm_g_cd : 1'b1;
    assign np_gnt = np_dm ? dm_g_np : 1'b1;

    // ---------------- responses: remember which slave answers each master next cycle
    reg [2:0] cd_src;          // 0 none/unmapped, 1 I-SRAM, 2 D-SRAM, 3 periph, 4 NPU regs
    reg       ci_src, np_src;  // 1 = valid SRAM data
    always @(posedge clk) begin
        if (!rst_n) begin
            ci_rv <= 0; cd_rv <= 0; np_rv <= 0; cd_src <= 0; ci_src <= 0; np_src <= 0;
        end else begin
            ci_rv  <= ci_req && ci_gnt;
            ci_src <= im_g_ci;
            cd_rv  <= cd_req && cd_gnt && !cd_we;
            cd_src <= (cd_req && !cd_we) ? (cd_im ? 3'd1 : cd_dm ? 3'd2 : cd_pr ? 3'd3 : cd_nr ? 3'd4 : 3'd0) : 3'd0;
            np_rv  <= np_req && np_gnt && !np_we;
            np_src <= dm_g_np;
        end
    end
    assign ci_rdata = ci_src ? im_rdata : 32'd0;
    assign np_rdata = np_src ? dm_rdata : 32'd0;
    assign cd_rdata = (cd_src == 3'd1) ? im_rdata : (cd_src == 3'd2) ? dm_rdata :
                      (cd_src == 3'd3) ? pr_rdata : (cd_src == 3'd4) ? nr_rdata : 32'd0;
endmodule

`default_nettype wire
