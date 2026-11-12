// ZAGROS-1  single-port synchronous SRAM, 32-bit words with byte enables (behavioural; maps to GF180 SRAM macros in
// the hardening flow). Read data appears the cycle after the access (ZG-BUS response timing).
`default_nettype none

module zg_sram #(
    parameter WORDS = 2048,
    parameter INIT  = ""           // optional $readmemh file (simulation / FPGA)
) (
    input  wire                     clk,
    input  wire                     en,
    input  wire                     we,
    input  wire [$clog2(WORDS)-1:0] addr,
    input  wire [31:0]              wdata,
    input  wire [3:0]               be,
    output reg  [31:0]              rdata
);
    reg [31:0] mem [0:WORDS-1];
    initial begin
        if (INIT != "") $readmemh(INIT, mem);
    end
    always @(posedge clk) begin
        if (en) begin
            if (we) begin
                if (be[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
                if (be[1]) mem[addr][15: 8] <= wdata[15: 8];
                if (be[2]) mem[addr][23:16] <= wdata[23:16];
                if (be[3]) mem[addr][31:24] <= wdata[31:24];
            end else begin
                rdata <= mem[addr];
            end
        end
    end
endmodule

`default_nettype wire
