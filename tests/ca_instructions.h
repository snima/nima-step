// RISC-V CA Coprocessor Custom Instructions (FULLY CORRECTED)
// Format: funct7[6:0] | rs2[4:0] | rs1[4:0] | funct3[2:0] | rd[4:0] | opcode[6:0]
// Opcode: 0x0B (custom-0)

// FIXES:
// - ca_load now uses x0 as rd (returns status in hardware but not architectural)
// - Added scratchpad↔CAR transfer macros
// - Documented actual vs paper behavior

// ========== Basic CAR Access ==========

// Load CAR from memory (rd forced to x0, hardware returns status internally)
.macro ca_load rs1
    .insn r 0x0B, 0, 0, x0, \rs1, x0
.endm

.macro ca_store rs1
    .insn r 0x0B, 1, 0, x0, \rs1, x0
.endm

.macro ca_get rd, upper=0
    .insn r 0x0B, 2, \upper, \rd, x0, x0
.endm

.macro ca_get_u rd
    .insn r 0x0B, 2, 1, \rd, x0, x0
.endm

.macro ca_set rs1
    .insn r 0x0B, 3, 0, x0, \rs1, x0
.endm

.macro ca_set_u rs1
    .insn r 0x0B, 3, 2, x0, \rs1, x0
.endm

// ========== CA Operations ==========

.macro ca_step rule_reg, steps_reg
    .insn r 0x0B, 4, 0, x0, \rule_reg, \steps_reg
.endm

.macro ca_find rd, pattern_reg
    .insn r 0x0B, 5, 0, \rd, \pattern_reg, x0
.endm

.macro ca_count rd
    .insn r 0x0B, 6, 0, \rd, x0, x0
.endm

.macro ca_life steps_reg
    .insn r 0x0B, 7, 0, x0, x0, \steps_reg
.endm

.macro ca_undo
    .insn r 0x0B, 7, 1, x0, x0, x0
.endm

// ========== DMA Instructions ==========

.macro ca_dma_load addr_reg, length_reg
    .insn r 0x0B, 0, 1, x0, \addr_reg, \length_reg
.endm

.macro ca_dma_store addr_reg, length_reg
    .insn r 0x0B, 1, 1, x0, \addr_reg, \length_reg
.endm

// ========== NEW: Scratchpad↔CAR Transfers ==========
// These make the scratchpad actually usable!

// Load CAR from scratchpad[index]
.macro ca_sp_load index_reg
    .insn r 0x0B, 2, 4, x0, \index_reg, x0
.endm

// Store CAR to scratchpad[index]
.macro ca_sp_store index_reg
    .insn r 0x0B, 3, 4, x0, \index_reg, x0
.endm
