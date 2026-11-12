// simulation wrapper: ZAGROS-1 SoC with firmware images loaded from the working directory (copied there by tb/run.py)
`default_nettype none
module tb_soc (
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
    output wire [31:0] post
);
    zg_soc #(.IINIT("isram.hex"), .DINIT("dsram.hex")) u_soc (
        .clk(clk), .rst_n_async(rst_n_async), .uart_tx(uart_tx), .uart_rx(uart_rx), .gpio_in(gpio_in),
        .gpio_out(gpio_out), .gpio_oe(gpio_oe), .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n), .post(post)
    );
endmodule
`default_nettype wire
