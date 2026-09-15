// Simplified CAM-style Huffman matcher for the measured pyflate workload.
//
// This is the one-table core. It stores one Huffman table and matches a
// 16-bit, MSB-first lookup window. huffman_find_six_table places six instances
// behind a selector, and huffman_find_simple_top adds the streaming reservoir.

// Simulation times are expressed in nanoseconds with picosecond precision.
// This directive does not set the synthesized circuit's clock frequency.
`timescale 1ns / 1ps

module hardware_dictionary_accelerator #(
    parameter int NUM_ENTRIES  = 147,
    parameter int KEY_WIDTH    = 16,
    parameter int SYMBOL_WIDTH = 9
)(
    input  logic                     clk,
    // Asynchronous assertion is supported. The system wrapper must synchronize
    // deassertion to clk so every register leaves reset on a safe clock edge.
    input  logic                     rst_n,

    // Dictionary programming interface. dict_wr_code is a right-aligned
    // canonical code; the core derives the MSB-aligned pattern and mask.
    input  logic                     dict_wr_en,
    input  logic [$clog2(NUM_ENTRIES)-1:0] dict_wr_addr,
    input  logic [KEY_WIDTH-1:0]     dict_wr_code,
    input  logic [SYMBOL_WIDTH-1:0]  dict_wr_symbol,
    input  logic [4:0]               dict_wr_len,

    // Lookup request channel. lookup_bits[KEY_WIDTH-1] is the next compressed
    // bit. A request transfers only when valid and ready are both high.
    input  logic                     lookup_valid,
    output logic                     lookup_ready,
    input  logic [KEY_WIDTH-1:0]     lookup_bits,

    // Registered result channel. A no-match lookup is still a valid result.
    output logic                     result_valid,
    input  logic                     result_ready,
    output logic                     match_found,
    output logic [SYMBOL_WIDTH-1:0]  match_symbol,
    output logic [4:0]               match_len
);

    // Dictionary Storage Elements
    logic [KEY_WIDTH-1:0]    pattern_mem [0:NUM_ENTRIES-1];
    logic [KEY_WIDTH-1:0]    mask_mem    [0:NUM_ENTRIES-1];
    logic [SYMBOL_WIDTH-1:0] symbol_mem  [0:NUM_ENTRIES-1];
    logic [4:0]              len_mem     [0:NUM_ENTRIES-1];
    logic [NUM_ENTRIES-1:0]  valid_mem;

    logic [NUM_ENTRIES-1:0]  raw_matches;
    logic                    candidate_found;
    logic [SYMBOL_WIDTH-1:0] candidate_symbol;
    logic [4:0]              candidate_len;

    // -------------------------------------------------------------------------
    // Configuration Logic: Writing entries to the Dictionary
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_mem <= '0;
        end else if (dict_wr_en && (dict_wr_addr < NUM_ENTRIES)) begin
            // The binary address width also represents values above
            // NUM_ENTRIES-1. Check the bound to prevent an out-of-range array
            // access and implementation-dependent simulation or synthesis
            // behavior.
            if ((dict_wr_len > 0) && (dict_wr_len <= KEY_WIDTH)) begin
                // The caller supplies a right-aligned code. Shift it and its
                // internally generated mask so lookup comparisons are MSB-first.
                pattern_mem[dict_wr_addr]
                    <= dict_wr_code << (KEY_WIDTH - dict_wr_len);
                mask_mem[dict_wr_addr]
                    <= {KEY_WIDTH{1'b1}} << (KEY_WIDTH - dict_wr_len);
                symbol_mem[dict_wr_addr] <= dict_wr_symbol;
                len_mem[dict_wr_addr]    <= dict_wr_len;
                valid_mem[dict_wr_addr]  <= 1'b1;
            end else begin
                // Length zero invalidates an entry. A length above KEY_WIDTH
                // is also invalid and must not cause an out-of-range shift.
                pattern_mem[dict_wr_addr] <= '0;
                mask_mem[dict_wr_addr]    <= '0;
                symbol_mem[dict_wr_addr]  <= '0;
                len_mem[dict_wr_addr]     <= '0;
                valid_mem[dict_wr_addr]   <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Fully-Parallel Matching Logic (CAM Match Engine)
    // -------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            // Including lookup_valid operand-gates comparison activity in banks
            // that are not selected by the six-table wrapper. This is not
            // physical clock gating: bank registers still receive clk.
            raw_matches[i] = lookup_valid
                           && valid_mem[i]
                           && ((lookup_bits & mask_mem[i]) == pattern_mem[i]);
        end
    end

    // -------------------------------------------------------------------------
    // Priority encoder: shortest prefix first, matching pyflate's behavior.
    // Legal Huffman tables are prefix-free, so normally exactly one valid
    // entry matches. The priority rule is deterministic for malformed tables.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // One-entry registered ready/valid output buffer
    // -------------------------------------------------------------------------
    // A request can enter when the output register is empty or when its current
    // result will be accepted on this clock edge.
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
        // While result_valid is high and result_ready is low, lookup_ready is
        // low and every result field holds stable under output backpressure.
    end

endmodule
