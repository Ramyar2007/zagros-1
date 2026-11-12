// ZAGROS-1  peripherals @ 0x4000_0000 (ZG-BUS slave, read data one cycle after the access)
//   0x0xxx UART : 00 DATA (w: send byte, r: received byte, clears RX_VALID)  04 STATUS [0]TX_BUSY [1]RX_VALID [2]RX_OVERRUN
//                 08 DIV (clock cycles per bit, >= 4)  0C CTRL [0] RX interrupt enable
//   0x1xxx GPIO : 00 OUT  04 IN (synchronised)  08 DIR (1 = output)
//   0x2xxx SPI  : 00 DATA (w: start a byte transfer, r: last byte received)  04 STATUS [0]BUSY  08 DIV (half period)  0C CS ([0] = cs_n level)
//   0x3xxx TIMER: 00 MTIME_LO  04 MTIME_HI  08 MTIMECMP_LO  0C MTIMECMP_HI   (irq_timer = mtime >= mtimecmp)
//   0xFxxx POST : 00 scratch/status word (firmware writes test results here)
// Every asynchronous input passes a 2-flop synchroniser.
`default_nettype none

module zg_periph (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire        we,
    input  wire [15:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  be,
    output reg  [31:0] rdata,
    // pins
    output reg         uart_tx,
    input  wire        uart_rx,
    input  wire [15:0] gpio_in,
    output reg  [15:0] gpio_out,
    output reg  [15:0] gpio_oe,
    output reg         spi_sclk,
    output reg         spi_mosi,
    input  wire        spi_miso,
    output reg         spi_cs_n,
    // interrupts
    output wire        irq_timer,
    output wire        irq_ext,
    output reg  [31:0] post
);
    /* verilator lint_off UNUSEDSIGNAL */
    wire [3:0] blk = addr[15:12];
    wire [3:0] reg_ = addr[5:2];
    wire [3:0] be_u = be;           // byte enables ignored: all peripheral registers are word registers
    /* verilator lint_on UNUSEDSIGNAL */
    wire wr = req && we;
    wire rd = req && !we;

    // ---------------- synchronisers
    reg [1:0]  rx_s;
    reg [1:0]  miso_s;
    reg [15:0] gin_s0, gin_s1;
    always @(posedge clk) begin
        if (!rst_n) begin rx_s <= 2'b11; miso_s <= 2'b00; gin_s0 <= 0; gin_s1 <= 0; end
        else begin rx_s <= {rx_s[0], uart_rx}; miso_s <= {miso_s[0], spi_miso}; gin_s0 <= gpio_in; gin_s1 <= gin_s0; end
    end
    wire rx_in = rx_s[1];

    // ---------------- UART
    reg [15:0] u_div;
    reg        u_rxie;
    // tx
    reg [9:0]  tx_sh;
    reg [3:0]  tx_bits;
    reg [15:0] tx_cnt;
    wire       tx_busy = tx_bits != 0;
    // rx
    reg [7:0]  rx_sh, rx_data;
    reg [3:0]  rx_bits;
    reg [15:0] rx_cnt;
    reg        rx_busy, rx_valid, rx_over;

    always @(posedge clk) begin
        if (!rst_n) begin
            u_div <= 16'd868; u_rxie <= 0; uart_tx <= 1'b1;
            tx_sh <= 10'h3FF; tx_bits <= 0; tx_cnt <= 0;
            rx_sh <= 0; rx_data <= 0; rx_bits <= 0; rx_cnt <= 0; rx_busy <= 0; rx_valid <= 0; rx_over <= 0;
        end else begin
            if (wr && blk == 4'h0 && reg_ == 4'h2) u_div <= (wdata[15:0] < 16'd4) ? 16'd4 : wdata[15:0];
            if (wr && blk == 4'h0 && reg_ == 4'h3) u_rxie <= wdata[0];
            // transmit
            if (wr && blk == 4'h0 && reg_ == 4'h0 && !tx_busy) begin
                tx_sh <= {1'b1, wdata[7:0], 1'b0}; tx_bits <= 4'd10; tx_cnt <= u_div;
                uart_tx <= 1'b0;
            end else if (tx_busy) begin
                if (tx_cnt == 16'd1) begin
                    tx_cnt <= u_div;
                    tx_sh <= {1'b1, tx_sh[9:1]};
                    tx_bits <= tx_bits - 1'b1;
                    uart_tx <= (tx_bits == 4'd1) ? 1'b1 : tx_sh[1];
                end else tx_cnt <= tx_cnt - 1'b1;
            end
            // receive: start bit, sample in the middle of each bit
            if (!rx_busy) begin
                if (!rx_in) begin rx_busy <= 1'b1; rx_cnt <= {1'b0, u_div[15:1]}; rx_bits <= 4'd0; end
            end else if (rx_cnt == 16'd0) begin
                rx_cnt <= u_div - 1'b1;
                if (rx_bits == 4'd0) begin
                    if (rx_in) rx_busy <= 1'b0;                       // false start
                    rx_bits <= 4'd1;
                end else if (rx_bits <= 4'd8) begin
                    rx_sh <= {rx_in, rx_sh[7:1]};
                    rx_bits <= rx_bits + 1'b1;
                end else begin                                         // stop bit
                    rx_busy <= 1'b0;
                    if (rx_valid) rx_over <= 1'b1;
                    rx_data <= rx_sh; rx_valid <= 1'b1;
                end
            end else rx_cnt <= rx_cnt - 1'b1;
            if (rd && blk == 4'h0 && reg_ == 4'h0) rx_valid <= 1'b0;
            if (wr && blk == 4'h0 && reg_ == 4'h1 && wdata[2]) rx_over <= 1'b0;
        end
    end
    assign irq_ext = rx_valid & u_rxie;

    // ---------------- GPIO
    always @(posedge clk) begin
        if (!rst_n) begin gpio_out <= 0; gpio_oe <= 0; end
        else begin
            if (wr && blk == 4'h1 && reg_ == 4'h0) gpio_out <= wdata[15:0];
            if (wr && blk == 4'h1 && reg_ == 4'h2) gpio_oe  <= wdata[15:0];
        end
    end

    // ---------------- SPI master (mode 0, MSB first)
    reg [15:0] s_div, s_cnt;
    reg [7:0]  s_sh, s_rx;
    reg [3:0]  s_bits;
    reg        s_busy;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_div <= 16'd4; s_cnt <= 0; s_sh <= 0; s_rx <= 0; s_bits <= 0; s_busy <= 0;
            spi_sclk <= 0; spi_mosi <= 0; spi_cs_n <= 1'b1;
        end else begin
            if (wr && blk == 4'h2 && reg_ == 4'h2) s_div <= (wdata[15:0] == 0) ? 16'd1 : wdata[15:0];
            if (wr && blk == 4'h2 && reg_ == 4'h3) spi_cs_n <= wdata[0];
            if (wr && blk == 4'h2 && reg_ == 4'h0 && !s_busy) begin
                s_busy <= 1'b1; s_sh <= wdata[7:0]; spi_mosi <= wdata[7]; s_bits <= 4'd8; s_cnt <= s_div; spi_sclk <= 1'b0;
            end else if (s_busy) begin
                if (s_cnt == 16'd1) begin
                    s_cnt <= s_div;
                    if (!spi_sclk) begin                       // rising edge: sample
                        spi_sclk <= 1'b1;
                        s_rx <= {s_rx[6:0], miso_s[1]};
                    end else begin                             // falling edge: shift out next bit
                        spi_sclk <= 1'b0;
                        s_sh <= {s_sh[6:0], 1'b0};
                        spi_mosi <= s_sh[6];
                        s_bits <= s_bits - 1'b1;
                        if (s_bits == 4'd1) s_busy <= 1'b0;
                    end
                end else s_cnt <= s_cnt - 1'b1;
            end
        end
    end

    // ---------------- TIMER
    reg [63:0] mtime, mtimecmp;
    always @(posedge clk) begin
        if (!rst_n) begin mtime <= 0; mtimecmp <= {64{1'b1}}; end
        else begin
            mtime <= mtime + 64'd1;
            if (wr && blk == 4'h3 && reg_ == 4'h0) mtime[31:0]     <= wdata;
            if (wr && blk == 4'h3 && reg_ == 4'h1) mtime[63:32]    <= wdata;
            if (wr && blk == 4'h3 && reg_ == 4'h2) mtimecmp[31:0]  <= wdata;
            if (wr && blk == 4'h3 && reg_ == 4'h3) mtimecmp[63:32] <= wdata;
        end
    end
    assign irq_timer = mtime >= mtimecmp;

    // ---------------- POST
    always @(posedge clk) begin
        if (!rst_n) post <= 0;
        else if (wr && blk == 4'hF && reg_ == 4'h0) post <= wdata;
    end

    // ---------------- read mux (registered)
    always @(posedge clk) begin
        if (!rst_n) rdata <= 0;
        else if (rd) begin
            case (blk)
                4'h0: case (reg_)
                        4'h0: rdata <= {24'd0, rx_data};
                        4'h1: rdata <= {29'd0, rx_over, rx_valid, tx_busy};
                        4'h2: rdata <= {16'd0, u_div};
                        4'h3: rdata <= {31'd0, u_rxie};
                        default: rdata <= 0;
                      endcase
                4'h1: case (reg_)
                        4'h0: rdata <= {16'd0, gpio_out};
                        4'h1: rdata <= {16'd0, gin_s1};
                        4'h2: rdata <= {16'd0, gpio_oe};
                        default: rdata <= 0;
                      endcase
                4'h2: case (reg_)
                        4'h0: rdata <= {24'd0, s_rx};
                        4'h1: rdata <= {31'd0, s_busy};
                        4'h2: rdata <= {16'd0, s_div};
                        4'h3: rdata <= {31'd0, spi_cs_n};
                        default: rdata <= 0;
                      endcase
                4'h3: case (reg_)
                        4'h0: rdata <= mtime[31:0];
                        4'h1: rdata <= mtime[63:32];
                        4'h2: rdata <= mtimecmp[31:0];
                        4'h3: rdata <= mtimecmp[63:32];
                        default: rdata <= 0;
                      endcase
                4'hF: rdata <= post;
                default: rdata <= 0;
            endcase
        end
    end
endmodule

`default_nettype wire
