`timescale 1ns/1ps

// ca_coprocessor.v - RISC-V CA Coprocessor with DMA 
// FIXES:
// - History counter now 4 bits (supports 8 entries)
// - Added scratchpad↔CAR transfer instructions
// - ca.load now returns status in rd_data
// - Pattern matcher uses standard Verilog (no [+:] syntax)
// - DMA state machine bug fixed (handles mem_ready properly)
// - All registers properly initialized

module ca_coprocessor (
    input wire clk,
    input wire rst_n,
    
    // CPU interface
    input wire        enable,
    input wire [2:0]  funct3,
    input wire [6:0]  funct7,
    input wire [31:0] rs1_data,
    input wire [31:0] rs2_data,
    input wire [11:0] imm,
    output reg [31:0] rd_data,
    output reg        ready,
    
    // Memory interface
    output reg [31:0] mem_addr,
    output reg [63:0] mem_wdata,
    input wire [63:0] mem_rdata,
    output reg        mem_we,
    output reg        mem_re,
    input wire        mem_ready
);

    // ========== Configuration ==========
    localparam SCRATCHPAD_SIZE = 256;  // 256 x 64-bit = 2KB
    localparam HISTORY_DEPTH = 8;
    
    // ========== Instruction Opcodes ==========
    localparam CA_LOAD    = 3'b000;
    localparam CA_STORE   = 3'b001;
    localparam CA_GET     = 3'b010;
    localparam CA_SET     = 3'b011;
    localparam CA_STEP    = 3'b100;
    localparam CA_FIND    = 3'b101;
    localparam CA_COUNT   = 3'b110;
    localparam CA_LIFE    = 3'b111;
    
    // Instruction variants (funct7 encoding)
    // NOTE: Priority - Scratchpad ops (funct7[2]) override upper ops (funct7[0,1])
    wire is_undo = (funct3 == CA_LIFE) && funct7[0];
    wire is_dma_load = (funct3 == CA_LOAD) && funct7[0];
    wire is_dma_store = (funct3 == CA_STORE) && funct7[0];
    wire set_upper = funct7[1];
    wire get_upper = funct7[0];
    
    // Scratchpad↔CAR transfer instructions (funct7[2])
    wire is_sp_to_car = (funct3 == CA_GET) && funct7[2];  // funct7=0x04
    wire is_car_to_sp = (funct3 == CA_SET) && funct7[2];  // funct7=0x04
    
    // ========== Registers ==========
    reg [63:0] CAR;
    reg [63:0] scratchpad [0:SCRATCHPAD_SIZE-1];
    reg [63:0] history [0:HISTORY_DEPTH-1];
    reg [2:0]  history_ptr;
    reg [3:0]  history_count;
    reg [7:0]  rule_reg;
    reg [15:0] step_counter;
    
    // DMA state
    reg [31:0] dma_addr;
    reg [15:0] dma_length;
    reg [15:0] dma_counter;
    reg        dma_direction;
    reg        dma_req_pending;  // FIX: Prevents missed transfers
    
    // ========== State Machine ==========
    reg [2:0] state;
    localparam IDLE        = 3'd0;
    localparam EVOLVE      = 3'd1;
    localparam MEM_OP      = 3'd2;
    localparam LIFE_EVOLVE = 3'd3;
    localparam DMA_XFER    = 3'd4;
    
    // ========== 1D CA Evolution ==========
    wire [63:0] next_car;
    genvar i;
    generate
        for (i = 0; i < 64; i = i + 1) begin : ca_cells
            wire left   = CAR[(i == 0) ? 63 : i-1];
            wire center = CAR[i];
            wire right  = CAR[(i == 63) ? 0 : i+1];
            wire [2:0] neighborhood = {left, center, right};
            assign next_car[i] = rule_reg[neighborhood];
        end
    endgenerate
    
    // ========== 2D Game of Life ==========
    wire [63:0] life_next;
    genvar life_i;
    generate
        for (life_i = 0; life_i < 64; life_i = life_i + 1) begin : life_cells
            wire [2:0] x = life_i[2:0];
            wire [2:0] y = life_i[5:3];
            
            wire [2:0] x_left  = (x == 0) ? 7 : x - 1;
            wire [2:0] x_right = (x == 7) ? 0 : x + 1;
            wire [2:0] y_up    = (y == 0) ? 7 : y - 1;
            wire [2:0] y_down  = (y == 7) ? 0 : y + 1;
            
            wire n_nw = CAR[{y_up,   x_left}];
            wire n_n  = CAR[{y_up,   x}];
            wire n_ne = CAR[{y_up,   x_right}];
            wire n_w  = CAR[{y,      x_left}];
            wire n_e  = CAR[{y,      x_right}];
            wire n_sw = CAR[{y_down, x_left}];
            wire n_s  = CAR[{y_down, x}];
            wire n_se = CAR[{y_down, x_right}];
            
            wire [3:0] neighbor_count = n_nw + n_n + n_ne + n_w + n_e + n_sw + n_s + n_se;
            
            assign life_next[life_i] = (neighbor_count == 4'd3) || 
                                       (CAR[life_i] && neighbor_count == 4'd2);
        end
    endgenerate
    
    // ========== Pattern Search ==========
    reg [31:0] pattern_index;
    integer j;
    always @(*) begin
        pattern_index = 32'hFFFFFFFF;
        for (j = 0; j < 33; j = j + 1) begin
            if (pattern_index == 32'hFFFFFFFF) begin
                case (j)
                    0:  if (CAR[31:0]   == rs1_data) pattern_index = 0;
                    1:  if (CAR[32:1]   == rs1_data) pattern_index = 1;
                    2:  if (CAR[33:2]   == rs1_data) pattern_index = 2;
                    3:  if (CAR[34:3]   == rs1_data) pattern_index = 3;
                    4:  if (CAR[35:4]   == rs1_data) pattern_index = 4;
                    5:  if (CAR[36:5]   == rs1_data) pattern_index = 5;
                    6:  if (CAR[37:6]   == rs1_data) pattern_index = 6;
                    7:  if (CAR[38:7]   == rs1_data) pattern_index = 7;
                    8:  if (CAR[39:8]   == rs1_data) pattern_index = 8;
                    9:  if (CAR[40:9]   == rs1_data) pattern_index = 9;
                    10: if (CAR[41:10]  == rs1_data) pattern_index = 10;
                    11: if (CAR[42:11]  == rs1_data) pattern_index = 11;
                    12: if (CAR[43:12]  == rs1_data) pattern_index = 12;
                    13: if (CAR[44:13]  == rs1_data) pattern_index = 13;
                    14: if (CAR[45:14]  == rs1_data) pattern_index = 14;
                    15: if (CAR[46:15]  == rs1_data) pattern_index = 15;
                    16: if (CAR[47:16]  == rs1_data) pattern_index = 16;
                    17: if (CAR[48:17]  == rs1_data) pattern_index = 17;
                    18: if (CAR[49:18]  == rs1_data) pattern_index = 18;
                    19: if (CAR[50:19]  == rs1_data) pattern_index = 19;
                    20: if (CAR[51:20]  == rs1_data) pattern_index = 20;
                    21: if (CAR[52:21]  == rs1_data) pattern_index = 21;
                    22: if (CAR[53:22]  == rs1_data) pattern_index = 22;
                    23: if (CAR[54:23]  == rs1_data) pattern_index = 23;
                    24: if (CAR[55:24]  == rs1_data) pattern_index = 24;
                    25: if (CAR[56:25]  == rs1_data) pattern_index = 25;
                    26: if (CAR[57:26]  == rs1_data) pattern_index = 26;
                    27: if (CAR[58:27]  == rs1_data) pattern_index = 27;
                    28: if (CAR[59:28]  == rs1_data) pattern_index = 28;
                    29: if (CAR[60:29]  == rs1_data) pattern_index = 29;
                    30: if (CAR[61:30]  == rs1_data) pattern_index = 30;
                    31: if (CAR[62:31]  == rs1_data) pattern_index = 31;
                    32: if (CAR[63:32]  == rs1_data) pattern_index = 32;
                endcase
            end
        end
    end
    
    // ========== Population Count ==========
    function [6:0] popcount;
        input [63:0] data;
        integer k;
        begin
            popcount = 0;
            for (k = 0; k < 64; k = k + 1)
                popcount = popcount + data[k];
        end
    endfunction
    
    // ========== Main FSM ==========
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            CAR <= 64'h0;
            state <= IDLE;
            ready <= 1'b0;
            step_counter <= 16'd0;
            mem_we <= 1'b0;
            mem_re <= 1'b0;
            rd_data <= 32'h0;
            rule_reg <= 8'h0;
            history_ptr <= 3'd0;
            history_count <= 4'd0;
            dma_counter <= 16'd0;
            dma_addr <= 32'h0;
            dma_length <= 16'h0;
            dma_direction <= 1'b0;
            dma_req_pending <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    ready <= 1'b0;
                    mem_we <= 1'b0;
                    mem_re <= 1'b0;
                    
                    if (enable) begin
                        if (is_undo) begin
                            // CA_UNDO: Restore previous state from history
                            if (history_count > 0) begin
                                history_ptr <= (history_ptr == 0) ? 7 : history_ptr - 1;
                                history_count <= history_count - 1;
                                CAR <= history[(history_ptr == 0) ? 7 : history_ptr - 1];
                            end
                            ready <= 1'b1;
                        end else if (is_sp_to_car) begin
                            // Transfer scratchpad[rs1] → CAR
                            CAR <= scratchpad[rs1_data[7:0]];
                            ready <= 1'b1;
                        end else if (is_car_to_sp) begin
                            // Transfer CAR → scratchpad[rs1]
                            scratchpad[rs1_data[7:0]] <= CAR;
                            ready <= 1'b1;
                        end else if (is_dma_load) begin
                            // DMA LOAD to scratchpad
                            if (rs2_data[15:0] > SCRATCHPAD_SIZE) begin
                                rd_data <= 32'hFFFFFFFF;  // Error code
                                ready <= 1'b1;
                            end else begin
                                dma_addr <= rs1_data;
                                dma_length <= rs2_data[15:0];
                                dma_counter <= 16'd0;
                                dma_direction <= 1'b0;
                                dma_req_pending <= 1'b0;
                                state <= DMA_XFER;
                            end
                        end else if (is_dma_store) begin
                            // DMA STORE from scratchpad
                            if (rs2_data[15:0] > SCRATCHPAD_SIZE) begin
                                rd_data <= 32'hFFFFFFFF;  // Error code
                                ready <= 1'b1;
                            end else begin
                                dma_addr <= rs1_data;
                                dma_length <= rs2_data[15:0];
                                dma_counter <= 16'd0;
                                dma_direction <= 1'b1;
                                dma_req_pending <= 1'b0;
                                state <= DMA_XFER;
                            end
                        end else begin
                            case (funct3)
                                CA_LOAD: begin
                                    mem_addr <= rs1_data;
                                    mem_re <= 1'b1;
                                    state <= MEM_OP;
                                end
                                
                                CA_STORE: begin
                                    mem_addr <= rs1_data;
                                    mem_wdata <= CAR;
                                    mem_we <= 1'b1;
                                    state <= MEM_OP;
                                end
                                
                                CA_GET: begin
                                    rd_data <= get_upper ? CAR[63:32] : CAR[31:0];
                                    ready <= 1'b1;
                                end
                                
                                CA_SET: begin
                                    if (set_upper) begin
                                        CAR[63:32] <= rs1_data;
                                    end else begin
                                        CAR <= {32'h0, rs1_data};
                                        history_ptr <= 3'd0;
                                        history_count <= 4'd0;
                                    end
                                    ready <= 1'b1;
                                end
                                
                                CA_STEP: begin
                                    rule_reg <= rs1_data[7:0];
                                    step_counter <= rs2_data[15:0];
                                    if (rs2_data[15:0] != 0) begin
                                        history[history_ptr] <= CAR;
                                        history_ptr <= (history_ptr == 7) ? 0 : history_ptr + 1;
                                        if (history_count < 8)
                                            history_count <= history_count + 1;
                                        state <= EVOLVE;
                                    end else begin
                                        ready <= 1'b1;
                                    end
                                end
                                
                                CA_FIND: begin
                                    rd_data <= pattern_index;
                                    ready <= 1'b1;
                                end
                                
                                CA_COUNT: begin
                                    rd_data <= {25'd0, popcount(CAR)};
                                    ready <= 1'b1;
                                end
                                
                                CA_LIFE: begin
                                    step_counter <= rs2_data[15:0];
                                    if (rs2_data[15:0] != 0) begin
                                        history[history_ptr] <= CAR;
                                        history_ptr <= (history_ptr == 7) ? 0 : history_ptr + 1;
                                        if (history_count < 8)
                                            history_count <= history_count + 1;
                                        state <= LIFE_EVOLVE;
                                    end else begin
                                        ready <= 1'b1;
                                    end
                                end
                                
                                default: ready <= 1'b1;
                            endcase
                        end
                    end
                end
                
                EVOLVE: begin
                    CAR <= next_car;
                    step_counter <= step_counter - 1;
                    if (step_counter == 1) begin
                        ready <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                LIFE_EVOLVE: begin
                    CAR <= life_next;
                    step_counter <= step_counter - 1;
                    if (step_counter == 1) begin
                        ready <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                MEM_OP: begin
                    if (mem_ready) begin
                        if (mem_re) begin
                            CAR <= mem_rdata;
                            mem_re <= 1'b0;
                            rd_data <= 32'h0;
                        end else if (mem_we) begin
                            mem_we <= 1'b0;
                            rd_data <= 32'h0;
                        end
                        ready <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                DMA_XFER: begin
                    if (dma_counter < dma_length) begin
                        if (dma_direction) begin
                            // Store: scratchpad -> memory
                            if (!dma_req_pending) begin
                                mem_addr <= dma_addr + (dma_counter << 3);
                                mem_wdata <= scratchpad[dma_counter[7:0]];
                                mem_we <= 1'b1;
                                dma_req_pending <= 1'b1;
                            end else if (mem_ready) begin
                                mem_we <= 1'b0;
                                dma_counter <= dma_counter + 1;
                                dma_req_pending <= 1'b0;
                            end
                        end else begin
                            // Load: memory -> scratchpad
                            if (!dma_req_pending) begin
                                mem_addr <= dma_addr + (dma_counter << 3);
                                mem_re <= 1'b1;
                                dma_req_pending <= 1'b1;
                            end else if (mem_ready) begin
                                scratchpad[dma_counter[7:0]] <= mem_rdata;
                                mem_re <= 1'b0;
                                dma_counter <= dma_counter + 1;
                                dma_req_pending <= 1'b0;
                            end
                        end
                    end else begin
                        rd_data <= 32'h0;  // Success
                        ready <= 1'b1;
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
