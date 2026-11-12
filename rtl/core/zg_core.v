// ZAGROS-1  ZG-CORE: RV32IMC, machine mode, 5-stage pipeline (IF, ID, EX, MEM, WB).
// - full forwarding into EX from MEM (ALU results) and WB (ALU + load data), regfile write-through to ID
// - load-use hazard: 1-cycle stall; branches/jumps resolved in EX (2-cycle penalty, static not-taken)
// - MUL* single-cycle in EX; DIV*/REM* iterative (stalls EX ~34 cycles)
// - traps taken in EX (precise): illegal instruction, ecall, ebreak, misaligned load/store; interrupts (timer,
//   external) are taken on the instruction in EX. mret in EX. CSRs read/written in EX.
// - ZG-BUS for instruction and data ports (data returns one cycle after the grant).
`default_nettype none

module zg_core #(
    parameter [31:0] BOOT = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst_n,
    // instruction port
    output wire        i_req,
    output wire [31:0] i_addr,
    input  wire        i_gnt,
    input  wire        i_rvalid,
    input  wire [31:0] i_rdata,
    // data port
    output wire        d_req,
    output wire        d_we,
    output wire [31:0] d_addr,
    output wire [31:0] d_wdata,
    output wire [3:0]  d_be,
    input  wire        d_gnt,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        d_rvalid,      // fixed one-cycle latency is assumed (ZG-BUS); kept for protocol checkers
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0] d_rdata,
    // interrupts (level, already synchronised)
    input  wire        irq_timer,
    input  wire        irq_ext,
    // debug / trace (retired instruction)
    output reg         rvfi_valid,
    output reg  [31:0] rvfi_pc
);
    // ======================================================================================= IF
    wire        redirect;
    wire [31:0] redirect_pc;
    wire        f_valid, f_is_c, f_ill_c;
    wire [31:0] f_instr, f_pc, f_raw;
    wire        id_ready;

    zg_fetch #(.BOOT(BOOT)) u_fetch (
        .clk(clk), .rst_n(rst_n),
        .i_req(i_req), .i_addr(i_addr), .i_gnt(i_gnt), .i_rvalid(i_rvalid), .i_rdata(i_rdata),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .o_valid(f_valid), .o_instr(f_instr), .o_pc(f_pc), .o_is_c(f_is_c), .o_illegal_c(f_ill_c), .o_raw(f_raw),
        .o_ready(id_ready)
    );

    // IF/ID register
    reg        d_v;
    reg [31:0] d_ins, d_pc, d_raw;
    reg        d_c, d_illc;

    // ======================================================================================= pipeline control
    wire ex_stall;          // EX cannot finish (divider busy, or MEM not advancing)
    wire mem_stall;         // MEM waiting for the data bus grant
    wire lu_stall;          // load-use hazard between ID and EX
    wire ex_adv_raw;        // EX may complete this cycle (MEM free, divider done or preempted)
    wire trap_now;          // EX takes a trap (exception or interrupt) this cycle

    // ID advances into EX when EX advances and no load-use hazard
    wire ex_adv  = !ex_stall;              // EX instruction moves to MEM this cycle
    wire id_adv  = ex_adv && !lu_stall;    // ID instruction moves to EX this cycle
    assign id_ready = id_adv || !d_v;      // IF/ID can accept from fetch

    // ======================================================================================= ID: decode
    wire [6:0] opc   = d_ins[6:0];
    wire [4:0] rd_a  = d_ins[11:7];
    wire [2:0] f3    = d_ins[14:12];
    wire [4:0] rs1_a = d_ins[19:15];
    wire [4:0] rs2_a = d_ins[24:20];
    wire [6:0] f7    = d_ins[31:25];

    wire [31:0] imm_i = {{20{d_ins[31]}}, d_ins[31:20]};
    wire [31:0] imm_s = {{20{d_ins[31]}}, d_ins[31:25], d_ins[11:7]};
    wire [31:0] imm_b = {{19{d_ins[31]}}, d_ins[31], d_ins[7], d_ins[30:25], d_ins[11:8], 1'b0};
    wire [31:0] imm_u = {d_ins[31:12], 12'd0};
    wire [31:0] imm_j = {{11{d_ins[31]}}, d_ins[31], d_ins[19:12], d_ins[20], d_ins[30:21], 1'b0};

    wire is_lui    = opc == 7'b0110111;
    wire is_auipc  = opc == 7'b0010111;
    wire is_jal    = opc == 7'b1101111;
    wire is_jalr   = opc == 7'b1100111 && f3 == 3'b000;
    wire is_branch = opc == 7'b1100011 && f3 != 3'b010 && f3 != 3'b011;
    wire is_load   = opc == 7'b0000011 && (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010 || f3 == 3'b100 || f3 == 3'b101);
    wire is_store  = opc == 7'b0100011 && (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010);
    wire is_opimm  = opc == 7'b0010011 && (f3 == 3'b001 ? f7 == 7'b0 : f3 == 3'b101 ? (f7 == 7'b0 || f7 == 7'b0100000) : 1'b1);
    wire is_op     = opc == 7'b0110011 && (f7 == 7'b0 || (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101)));
    wire is_muldiv = opc == 7'b0110011 && f7 == 7'b0000001;
    wire is_fence  = opc == 7'b0001111 && (f3 == 3'b000 || f3 == 3'b001);     // fence, fence.i: no-ops here
    wire is_system = opc == 7'b1110011;
    wire is_ecall  = is_system && d_ins[31:7] == 25'd0;
    wire is_ebreak = is_system && d_ins[31:7] == {12'd1, 13'd0};
    wire is_mret   = is_system && d_ins[31:7] == {12'h302, 13'd0};
    wire is_wfi    = is_system && d_ins[31:7] == {12'h105, 13'd0};
    wire is_csr    = is_system && f3 != 3'b000 && f3 != 3'b100;

    wire dec_ok = is_lui | is_auipc | is_jal | is_jalr | is_branch | is_load | is_store | is_opimm | is_op |
                  is_muldiv | is_fence | is_ecall | is_ebreak | is_mret | is_wfi | is_csr;
    wire d_illegal = d_illc || !dec_ok || (!d_c && d_ins[1:0] != 2'b11);

    wire uses_rs1 = is_jalr | is_branch | is_load | is_store | is_opimm | is_op | is_muldiv | (is_csr & ~f3[2]);
    wire uses_rs2 = is_branch | is_store | is_op | is_muldiv;
    wire writes_rd = (is_lui | is_auipc | is_jal | is_jalr | is_load | is_opimm | is_op | is_muldiv | is_csr) && rd_a != 5'd0;

    // register file (x1..x31), write in WB, read with write-through
    reg  [31:0] rf [1:31];
    wire        w_en;
    wire [4:0]  w_rd;
    wire [31:0] w_data;
    wire [31:0] rs1_v = (rs1_a == 5'd0) ? 32'd0 : (w_en && w_rd == rs1_a) ? w_data : rf[rs1_a];
    wire [31:0] rs2_v = (rs2_a == 5'd0) ? 32'd0 : (w_en && w_rd == rs2_a) ? w_data : rf[rs2_a];

    // ======================================================================================= ID/EX register
    reg        e_v;
    reg [31:0] e_pc, e_raw, e_rs1v, e_rs2v, e_imm;
    reg [4:0]  e_rs1, e_rs2, e_rd;
    reg [2:0]  e_f3;
    reg        e_c, e_wr, e_ill;
    reg        e_lui, e_auipc, e_jal, e_jalr, e_br, e_ld, e_st, e_opimm, e_op, e_md, e_ecall, e_ebreak, e_mret, e_csr;
    reg        e_sub, e_sra;   // f7 bit 5 for op / shift-right-arith
    reg [11:0] e_csra;

    // load-use: EX holds a load whose rd is a source of the ID instruction
    assign lu_stall = e_v && e_ld && e_wr && d_v &&
                      ((uses_rs1 && rs1_a == e_rd) || (uses_rs2 && rs2_a == e_rd));

    // ======================================================================================= EX/MEM, MEM/WB registers
    reg        m_v, m_ld, m_st, m_wr;
    reg [4:0]  m_rd;
    reg [31:0] m_res, m_addr, m_wdat, m_pc;
    reg [3:0]  m_be;
    reg [2:0]  m_f3;

    reg        w_v, w_ld, w_wr;
    reg [4:0]  w_rd_r;
    reg [31:0] w_res, w_pc;
    reg [2:0]  w_f3;
    reg [1:0]  w_off;

    // ======================================================================================= EX: operands with forwarding
    // load data formatting in WB
    wire [31:0] ld_sh = d_rdata >> {w_off, 3'b000};
    wire [31:0] ld_v  = (w_f3 == 3'b000) ? {{24{ld_sh[7]}},  ld_sh[7:0]}  :
                        (w_f3 == 3'b001) ? {{16{ld_sh[15]}}, ld_sh[15:0]} :
                        (w_f3 == 3'b100) ? {24'd0, ld_sh[7:0]} :
                        (w_f3 == 3'b101) ? {16'd0, ld_sh[15:0]} : ld_sh;
    assign w_en   = w_v && w_wr;
    assign w_rd   = w_rd_r;
    assign w_data = w_ld ? ld_v : w_res;

    wire fwd_m1 = m_v && m_wr && !m_ld && m_rd == e_rs1 && e_rs1 != 5'd0;
    wire fwd_m2 = m_v && m_wr && !m_ld && m_rd == e_rs2 && e_rs2 != 5'd0;
    wire fwd_w1 = w_en && w_rd == e_rs1 && e_rs1 != 5'd0;
    wire fwd_w2 = w_en && w_rd == e_rs2 && e_rs2 != 5'd0;
    wire [31:0] op1 = fwd_m1 ? m_res : fwd_w1 ? w_data : e_rs1v;
    wire [31:0] op2 = fwd_m2 ? m_res : fwd_w2 ? w_data : e_rs2v;

    // ALU
    wire [31:0] alu_b   = (e_opimm) ? e_imm : op2;
    wire        do_sub  = e_op && e_sub;
    wire [31:0] add_r   = do_sub ? (op1 - alu_b) : (op1 + alu_b);
    wire        lt_s    = $signed(op1) < $signed(alu_b);
    wire        lt_u    = op1 < alu_b;
    wire [4:0]  shamt   = alu_b[4:0];
    wire [31:0] sra_r   = $signed(op1) >>> shamt;
    reg  [31:0] alu_r;
    always @(*) begin
        case (e_f3)
            3'b000: alu_r = add_r;
            3'b001: alu_r = op1 << shamt;
            3'b010: alu_r = {31'd0, lt_s};
            3'b011: alu_r = {31'd0, lt_u};
            3'b100: alu_r = op1 ^ alu_b;
            3'b101: alu_r = e_sra ? sra_r : (op1 >> shamt);
            3'b110: alu_r = op1 | alu_b;
            default: alu_r = op1 & alu_b;
        endcase
    end

    // multiplier (MUL, MULH, MULHSU, MULHU)
    wire        ma_s  = (e_f3 == 3'b001) || (e_f3 == 3'b010);
    wire        mb_s  = (e_f3 == 3'b001);
    wire signed [32:0] ma = {ma_s & op1[31], op1};
    wire signed [32:0] mb = {mb_s & op2[31], op2};
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [65:0] mp = ma * mb;      // bits 65:64 are sign copies
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] mul_r = (e_f3 == 3'b000) ? mp[31:0] : mp[63:32];

    // divider
    wire        is_div  = e_v && e_md && e_f3[2];
    wire        div_busy, div_done;
    wire [31:0] div_r;
    reg         div_fired;          // started for the current EX instruction
    wire        div_start = is_div && !div_fired && !div_busy && !trap_now;
    zg_div u_div (.clk(clk), .rst_n(rst_n), .start(div_start), .op(e_f3[1:0]), .a(op1), .b(op2),
                  .busy(div_busy), .done(div_done), .result(div_r));
    reg         div_have;           // result captured, waiting for EX to advance
    reg  [31:0] div_res;
    wire        div_wait = is_div && !(div_have || (div_done && div_fired));   // ignore a preempted divide's late result

    // branches
    reg br_take;
    always @(*) begin
        case (e_f3)
            3'b000: br_take = op1 == op2;
            3'b001: br_take = op1 != op2;
            3'b100: br_take = $signed(op1) < $signed(op2);
            3'b101: br_take = $signed(op1) >= $signed(op2);
            3'b110: br_take = op1 < op2;
            default: br_take = op1 >= op2;
        endcase
    end
    wire [31:0] pc_next  = e_pc + (e_c ? 32'd2 : 32'd4);
    wire [31:0] br_tgt   = e_pc + e_imm;
    wire [31:0] jalr_tgt = (op1 + e_imm) & 32'hFFFF_FFFE;

    // load/store address + alignment
    wire [31:0] ls_addr  = op1 + e_imm;
    wire        mis_ld   = e_ld && ((e_f3[1:0] == 2'b01 && ls_addr[0]) || (e_f3[1:0] == 2'b10 && ls_addr[1:0] != 2'b00));
    wire        mis_st   = e_st && ((e_f3[1:0] == 2'b01 && ls_addr[0]) || (e_f3[1:0] == 2'b10 && ls_addr[1:0] != 2'b00));
    wire [3:0]  st_be    = (e_f3[1:0] == 2'b00) ? (4'b0001 << ls_addr[1:0]) :
                           (e_f3[1:0] == 2'b01) ? (4'b0011 << ls_addr[1:0]) : 4'b1111;
    wire [31:0] st_data  = (e_f3[1:0] == 2'b00) ? {4{op2[7:0]}} : (e_f3[1:0] == 2'b01) ? {2{op2[15:0]}} : op2;

    // ======================================================================================= CSRs
    reg        mstatus_mie, mstatus_mpie;
    reg [31:0] mtvec, mepc, mcause, mtval, mscratch;
    reg        mie_mtie, mie_meie;
    reg [63:0] mcycle, minstret;
    wire       mip_mtip = irq_timer;
    wire       mip_meip = irq_ext;

    reg        csr_ok;
    reg [31:0] csr_rv;
    always @(*) begin
        csr_ok = 1'b1;
        case (e_csra)
            12'h300: csr_rv = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
            12'h301: csr_rv = 32'h4000_1104;                     // RV32 I M C
            12'h304: csr_rv = {20'd0, mie_meie, 3'd0, mie_mtie, 7'd0};
            12'h305: csr_rv = mtvec;
            12'h340: csr_rv = mscratch;
            12'h341: csr_rv = mepc;
            12'h342: csr_rv = mcause;
            12'h343: csr_rv = mtval;
            12'h344: csr_rv = {20'd0, mip_meip, 3'd0, mip_mtip, 7'd0};
            12'hB00, 12'hC00: csr_rv = mcycle[31:0];
            12'hB80, 12'hC80: csr_rv = mcycle[63:32];
            12'hB02, 12'hC02: csr_rv = minstret[31:0];
            12'hB82, 12'hC82: csr_rv = minstret[63:32];
            12'hF11, 12'hF12, 12'hF13, 12'hF14: csr_rv = 32'd0;  // vendor, arch, impl, hart id
            default: begin csr_rv = 32'd0; csr_ok = 1'b0; end
        endcase
    end
    wire [31:0] csr_src  = e_f3[2] ? {27'd0, e_rs1} : op1;            // immediate forms use the rs1 field as zimm
    wire        csr_wr   = !(e_f3[1] && e_rs1 == 5'd0);                // csrrs/csrrc with x0/zimm 0 do not write
    wire [31:0] csr_new  = (e_f3[1:0] == 2'b01) ? csr_src :
                           (e_f3[1:0] == 2'b10) ? (csr_rv | csr_src) : (csr_rv & ~csr_src);
    wire        csr_ro   = e_csra[11:10] == 2'b11;
    wire        csr_bad  = e_csr && (!csr_ok || (csr_ro && csr_wr));

    // ======================================================================================= traps
    wire        irq_pend = mstatus_mie && ((mie_mtie && mip_mtip) || (mie_meie && mip_meip));
    wire        exc_ill  = e_ill || csr_bad;
    wire        exc      = e_v && (exc_ill || e_ecall || e_ebreak || mis_ld || mis_st);
    wire        take_irq = e_v && irq_pend && !exc;
    assign      trap_now = (exc || take_irq) && ex_adv_raw;
    wire [31:0] trap_cause = take_irq ? (mie_meie && mip_meip ? 32'h8000_000B : 32'h8000_0007) :
                             exc_ill ? 32'd2 : e_ebreak ? 32'd3 : e_ecall ? 32'd11 : mis_ld ? 32'd4 : 32'd6;
    wire [31:0] trap_val   = exc_ill ? e_raw : (mis_ld || mis_st) ? ls_addr : 32'd0;

    // EX can finish when MEM can take it and the divider (if any) is done
    assign ex_adv_raw = !mem_stall && !(div_wait && !take_irq);
    assign ex_stall = !ex_adv_raw;

    wire ex_go   = e_v && ex_adv_raw && !trap_now;          // EX instruction completes normally this cycle
    wire jump    = ex_go && (e_jal || e_jalr || (e_br && br_take) || e_mret);
    assign redirect    = trap_now || jump;
    assign redirect_pc = trap_now ? {mtvec[31:2], 2'b00} :
                         e_mret   ? mepc :
                         e_jalr   ? jalr_tgt :
                         e_jal    ? br_tgt : br_tgt;

    // EX result
    wire [31:0] ex_res = e_lui   ? e_imm :
                         e_auipc ? e_pc + e_imm :
                         (e_jal || e_jalr) ? pc_next :
                         e_csr   ? csr_rv :
                         e_md    ? (e_f3[2] ? (div_have ? div_res : div_r) : mul_r) :
                         alu_r;

    // ======================================================================================= MEM
    assign d_req   = m_v && (m_ld || m_st);
    assign d_we    = m_st;
    assign d_addr  = {m_addr[31:2], 2'b00};
    assign d_wdata = m_wdat;
    assign d_be    = m_st ? m_be : 4'b1111;
    assign mem_stall = d_req && !d_gnt;

    // ======================================================================================= sequential
    always @(posedge clk) begin
        if (!rst_n) begin
            d_v <= 1'b0; e_v <= 1'b0; m_v <= 1'b0; w_v <= 1'b0;
            d_ins <= 32'h13; d_pc <= 0; d_raw <= 0; d_c <= 0; d_illc <= 0;
            e_pc <= 0; e_raw <= 0; e_rs1v <= 0; e_rs2v <= 0; e_imm <= 0; e_rs1 <= 0; e_rs2 <= 0; e_rd <= 0; e_f3 <= 0;
            {e_c, e_wr, e_ill, e_lui, e_auipc, e_jal, e_jalr, e_br, e_ld, e_st, e_opimm, e_op, e_md, e_ecall, e_ebreak, e_mret, e_csr, e_sub, e_sra} <= 19'd0;
            e_csra <= 0;
            m_ld <= 0; m_st <= 0; m_wr <= 0; m_rd <= 0; m_res <= 0; m_addr <= 0; m_wdat <= 0; m_be <= 0; m_f3 <= 0; m_pc <= 0;
            w_ld <= 0; w_wr <= 0; w_rd_r <= 0; w_res <= 0; w_f3 <= 0; w_off <= 0; w_pc <= 0;
            mstatus_mie <= 0; mstatus_mpie <= 0; mtvec <= 0; mepc <= 0; mcause <= 0; mtval <= 0; mscratch <= 0;
            mie_mtie <= 0; mie_meie <= 0; mcycle <= 0; minstret <= 0;
            div_fired <= 0; div_have <= 0; div_res <= 0;
            rvfi_valid <= 0; rvfi_pc <= 0;
        end else begin
            mcycle <= mcycle + 64'd1;

            // ---------------- IF -> ID
            if (redirect) begin
                d_v <= 1'b0;
            end else if (id_ready) begin
                d_v <= f_valid;
                if (f_valid) begin
                    d_ins <= f_instr; d_pc <= f_pc; d_raw <= f_raw; d_c <= f_is_c; d_illc <= f_ill_c;
                end
            end

            // ---------------- ID -> EX
            if (redirect) begin
                e_v <= 1'b0;
            end else if (id_adv) begin
                e_v <= d_v;
                e_pc <= d_pc; e_raw <= d_raw; e_c <= d_c;
                e_rs1v <= rs1_v; e_rs2v <= rs2_v;
                e_rs1 <= uses_rs1 || is_csr ? rs1_a : 5'd0;
                e_rs2 <= uses_rs2 ? rs2_a : 5'd0;
                e_rd <= rd_a; e_f3 <= f3; e_wr <= writes_rd; e_ill <= d_illegal;
                e_imm <= is_lui || is_auipc ? imm_u : is_jal ? imm_j : is_branch ? imm_b : is_store ? imm_s : imm_i;
                e_lui <= is_lui; e_auipc <= is_auipc; e_jal <= is_jal; e_jalr <= is_jalr; e_br <= is_branch;
                e_ld <= is_load; e_st <= is_store; e_opimm <= is_opimm; e_op <= is_op; e_md <= is_muldiv;
                e_ecall <= is_ecall; e_ebreak <= is_ebreak; e_mret <= is_mret; e_csr <= is_csr;
                e_sub <= f7[5]; e_sra <= f7[5]; e_csra <= d_ins[31:20];
            end else if (ex_adv_raw) begin
                e_v <= 1'b0;                     // load-use bubble
            end

            // ---------------- divider bookkeeping
            if (div_start) div_fired <= 1'b1;
            if (div_done && is_div && div_fired) begin div_have <= 1'b1; div_res <= div_r; end
            if (ex_adv_raw || redirect) begin div_fired <= 1'b0; div_have <= 1'b0; end

            // ---------------- EX -> MEM
            if (ex_adv_raw) begin
                m_v   <= ex_go;
                m_ld  <= e_ld; m_st <= e_st; m_wr <= e_wr && !(e_ld);
                m_rd  <= e_rd; m_res <= ex_res; m_addr <= ls_addr; m_f3 <= e_f3; m_pc <= e_pc;
                m_wdat <= st_data; m_be <= st_be;
                if (e_ld) m_wr <= e_wr;
            end else if (!mem_stall) begin
                m_v <= 1'b0;
            end

            // ---------------- CSR / trap side effects (only when EX actually completes or traps)
            if (trap_now) begin
                mepc   <= e_pc;
                mcause <= trap_cause;
                mtval  <= trap_val;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (ex_go) begin
                if (e_mret) begin
                    mstatus_mie  <= mstatus_mpie;
                    mstatus_mpie <= 1'b1;
                end
                if (e_csr && csr_wr) begin
                    case (e_csra)
                        12'h300: begin mstatus_mie <= csr_new[3]; mstatus_mpie <= csr_new[7]; end
                        12'h304: begin mie_mtie <= csr_new[7]; mie_meie <= csr_new[11]; end
                        12'h305: mtvec    <= {csr_new[31:2], 2'b00};
                        12'h340: mscratch <= csr_new;
                        12'h341: mepc     <= {csr_new[31:1], 1'b0};
                        12'h342: mcause   <= csr_new;
                        12'h343: mtval    <= csr_new;
                        12'hB00: mcycle[31:0]    <= csr_new;
                        12'hB80: mcycle[63:32]   <= csr_new;
                        12'hB02: minstret[31:0]  <= csr_new;
                        12'hB82: minstret[63:32] <= csr_new;
                        default: ;
                    endcase
                end
            end

            // ---------------- MEM -> WB
            if (!mem_stall) begin
                w_v <= m_v; w_ld <= m_ld; w_wr <= m_wr; w_rd_r <= m_rd; w_res <= m_res; w_f3 <= m_f3;
                w_off <= m_addr[1:0]; w_pc <= m_pc;
            end else begin
                w_v <= 1'b0;
            end

            // ---------------- WB
            if (w_en) rf[w_rd] <= w_data;
            rvfi_valid <= w_v;
            rvfi_pc    <= w_pc;
            if (w_v) minstret <= minstret + 64'd1;
        end
    end
endmodule

`default_nettype wire
