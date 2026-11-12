// ZAGROS-1  RVC expander: 16-bit compressed instruction -> equivalent 32-bit RV32I instruction (RV32C, no F/D).
// illegal=1 for reserved/illegal encodings (including the all-zero halfword).
`default_nettype none

module zg_rvc (
    input  wire [15:0] c,
    output reg  [31:0] i,
    output reg         illegal
);
    wire [4:0] rd    = c[11:7];
    wire [4:0] rs2   = c[6:2];
    wire [4:0] rdp   = {2'b01, c[4:2]};     // rd'/rs2' (x8-x15)
    wire [4:0] rs1p  = {2'b01, c[9:7]};     // rs1'/rd'

    // immediates
    wire [11:0] imm_addi4spn = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00};
    wire [11:0] imm_lw       = {5'b0, c[5], c[12:10], c[6], 2'b00};
    wire [11:0] imm_ci       = {{7{c[12]}}, c[6:2]};
    wire [11:0] imm_addi16sp = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0};
    wire [19:0] imm_lui      = {{15{c[12]}}, c[6:2]};
    wire [11:0] imm_lwsp     = {4'b0, c[3:2], c[12], c[6:4], 2'b00};
    wire [11:0] imm_swsp     = {4'b0, c[8:7], c[12:9], 2'b00};
    // jal offset bits [11:1]
    wire [20:0] imm_j  = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
    // branch offset bits [8:1]
    wire [12:0] imm_b  = {{5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};

    localparam OP_IMM = 7'b0010011, OP = 7'b0110011, LOAD = 7'b0000011, STORE = 7'b0100011,
               LUI = 7'b0110111, JAL = 7'b1101111, JALR = 7'b1100111, BRANCH = 7'b1100011, SYSTEM = 7'b1110011;

    always @(*) begin
        i = 32'h0000_0013;          // nop
        illegal = 1'b0;
        case ({c[1:0], c[15:13]})
            // ---------------- quadrant 0
            5'b00_000: begin        // c.addi4spn
                if (imm_addi4spn == 0) illegal = 1'b1;
                i = {imm_addi4spn, 5'd2, 3'b000, rdp, OP_IMM};
            end
            5'b00_010: i = {imm_lw, rs1p, 3'b010, rdp, LOAD};                                   // c.lw
            5'b00_110: i = {imm_lw[11:5], rdp, rs1p, 3'b010, imm_lw[4:0], STORE};               // c.sw
            // ---------------- quadrant 1
            5'b01_000: i = {imm_ci, rd, 3'b000, rd, OP_IMM};                                    // c.addi / c.nop
            5'b01_001: i = {imm_j[20], imm_j[10:1], imm_j[11], imm_j[19:12], 5'd1, JAL};        // c.jal
            5'b01_010: i = {imm_ci, 5'd0, 3'b000, rd, OP_IMM};                                  // c.li
            5'b01_011: begin
                if (rd == 5'd2) begin   // c.addi16sp
                    if (imm_addi16sp == 0) illegal = 1'b1;
                    i = {imm_addi16sp, 5'd2, 3'b000, 5'd2, OP_IMM};
                end else begin          // c.lui
                    if (imm_lui == 0) illegal = 1'b1;
                    i = {imm_lui, rd, LUI};
                end
            end
            5'b01_100: begin
                case (c[11:10])
                    2'b00: begin if (c[12]) illegal = 1'b1; i = {7'b0000000, c[6:2], rs1p, 3'b101, rs1p, OP_IMM}; end  // c.srli
                    2'b01: begin if (c[12]) illegal = 1'b1; i = {7'b0100000, c[6:2], rs1p, 3'b101, rs1p, OP_IMM}; end  // c.srai
                    2'b10: i = {imm_ci, rs1p, 3'b111, rs1p, OP_IMM};                                                   // c.andi
                    2'b11: begin
                        if (c[12]) illegal = 1'b1;                                                                      // RV64 only
                        case (c[6:5])
                            2'b00: i = {7'b0100000, rdp, rs1p, 3'b000, rs1p, OP};   // c.sub
                            2'b01: i = {7'b0000000, rdp, rs1p, 3'b100, rs1p, OP};   // c.xor
                            2'b10: i = {7'b0000000, rdp, rs1p, 3'b110, rs1p, OP};   // c.or
                            2'b11: i = {7'b0000000, rdp, rs1p, 3'b111, rs1p, OP};   // c.and
                        endcase
                    end
                endcase
            end
            5'b01_101: i = {imm_j[20], imm_j[10:1], imm_j[11], imm_j[19:12], 5'd0, JAL};        // c.j
            5'b01_110: i = {imm_b[12], imm_b[10:5], 5'd0, rs1p, 3'b000, imm_b[4:1], imm_b[11], BRANCH}; // c.beqz
            5'b01_111: i = {imm_b[12], imm_b[10:5], 5'd0, rs1p, 3'b001, imm_b[4:1], imm_b[11], BRANCH}; // c.bnez
            // ---------------- quadrant 2
            5'b10_000: begin if (c[12]) illegal = 1'b1; i = {7'b0000000, c[6:2], rd, 3'b001, rd, OP_IMM}; end  // c.slli
            5'b10_010: begin if (rd == 0) illegal = 1'b1; i = {imm_lwsp, 5'd2, 3'b010, rd, LOAD}; end          // c.lwsp
            5'b10_100: begin
                if (!c[12]) begin
                    if (rs2 == 0) begin     // c.jr
                        if (rd == 0) illegal = 1'b1;
                        i = {12'd0, rd, 3'b000, 5'd0, JALR};
                    end else                // c.mv
                        i = {7'b0000000, rs2, 5'd0, 3'b000, rd, OP};
                end else begin
                    if (rs2 == 0) begin
                        if (rd == 0) i = {12'd1, 5'd0, 3'b000, 5'd0, SYSTEM};      // c.ebreak
                        else         i = {12'd0, rd, 3'b000, 5'd1, JALR};          // c.jalr
                    end else
                        i = {7'b0000000, rs2, rd, 3'b000, rd, OP};                  // c.add
                end
            end
            5'b10_110: i = {imm_swsp[11:5], rs2, 5'd2, 3'b010, imm_swsp[4:0], STORE};          // c.swsp
            default: illegal = 1'b1;   // FP loads/stores, reserved
        endcase
        if (c == 16'h0000) illegal = 1'b1;
    end
endmodule

`default_nettype wire
