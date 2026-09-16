`timescale 1ns / 1ps

module hardware_dictionary_accelerator #(
    parameter int NUM_ENTRIES  = 147,
    parameter int KEY_WIDTH    = 16,
    parameter int SYMBOL_WIDTH = 9
)(
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     dict_wr_en,
    input  logic [$clog2(NUM_ENTRIES)-1:0] dict_wr_addr,
    input  logic [KEY_WIDTH-1:0]     dict_wr_code,
    input  logic [SYMBOL_WIDTH-1:0]  dict_wr_symbol,
    input  logic [4:0]               dict_wr_len,

    input  logic                     lookup_valid,
    output logic                     lookup_ready,
    input  logic [KEY_WIDTH-1:0]     lookup_bits,

    output logic                     result_valid,
    input  logic                     result_ready,
    output logic                     match_found,
    output logic [SYMBOL_WIDTH-1:0]  match_symbol,
    output logic [4:0]               match_len
);

    logic [KEY_WIDTH-1:0]    pattern_mem [0:NUM_ENTRIES-1];
    logic [KEY_WIDTH-1:0]    mask_mem    [0:NUM_ENTRIES-1];
    logic [SYMBOL_WIDTH-1:0] symbol_mem  [0:NUM_ENTRIES-1];
    logic [4:0]              len_mem     [0:NUM_ENTRIES-1];
    logic [NUM_ENTRIES-1:0]  valid_mem;

    logic [NUM_ENTRIES-1:0]  raw_matches;
    logic                    candidate_found;
    logic [SYMBOL_WIDTH-1:0] candidate_symbol;
    logic [4:0]              candidate_len;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_mem <= '0;
        end else if (dict_wr_en && (dict_wr_addr < NUM_ENTRIES)) begin
            if ((dict_wr_len > 0) && (dict_wr_len <= KEY_WIDTH)) begin
                pattern_mem[dict_wr_addr]
                    <= dict_wr_code << (KEY_WIDTH - dict_wr_len);
                mask_mem[dict_wr_addr]
                    <= {KEY_WIDTH{1'b1}} << (KEY_WIDTH - dict_wr_len);
                symbol_mem[dict_wr_addr] <= dict_wr_symbol;
                len_mem[dict_wr_addr]    <= dict_wr_len;
                valid_mem[dict_wr_addr]  <= 1'b1;
            end else begin
                pattern_mem[dict_wr_addr] <= '0;
                mask_mem[dict_wr_addr]    <= '0;
                symbol_mem[dict_wr_addr]  <= '0;
                len_mem[dict_wr_addr]     <= '0;
                valid_mem[dict_wr_addr]   <= 1'b0;
            end
        end
    end

    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            raw_matches[i] = lookup_valid
                           && valid_mem[i]
                           && ((lookup_bits & mask_mem[i]) == pattern_mem[i]);
        end
    end

    always_comb begin
        candidate_found  = 1'b0;
        candidate_symbol = '0;
        candidate_len    = '0;

        for (int l = 1; l <= KEY_WIDTH; l++) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                if (!candidate_found
                        && raw_matches[i]
                        && (len_mem[i] == l)) begin
                    candidate_found  = 1'b1;
                    candidate_symbol = symbol_mem[i];
                    candidate_len    = len_mem[i];
                end
            end
        end
    end

    assign lookup_ready = !result_valid || result_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            match_found  <= 1'b0;
            match_symbol <= '0;
            match_len    <= '0;
        end else if (lookup_ready) begin
            result_valid <= lookup_valid;

            if (lookup_valid) begin
                match_found  <= candidate_found;
                match_symbol <= candidate_symbol;
                match_len    <= candidate_len;
            end else begin
                match_found  <= 1'b0;
                match_symbol <= '0;
                match_len    <= '0;
            end
        end
    end

endmodule
