// Six-bank wrapper around the Section 1 CAM matcher.
// Only the selected bank receives lookup_valid, which suppresses unnecessary
// switching in the other five banks. All six tables remain immediately
// available, so a bzip2 selector change does not require reprogramming.

`timescale 1ns / 1ps

module huffman_find_six_table #(
    parameter int NUM_TABLES   = 6,
    parameter int NUM_ENTRIES  = 147,
    parameter int KEY_WIDTH    = 16,
    parameter int SYMBOL_WIDTH = 9
)(
    input  logic                              clk,
    // Assert asynchronously; deassert synchronously in the system wrapper.
    input  logic                              rst_n,

    input  logic                              dict_wr_en,
    input  logic [$clog2(NUM_TABLES)-1:0]     dict_wr_table,
    input  logic [$clog2(NUM_ENTRIES)-1:0]    dict_wr_addr,
    input  logic [KEY_WIDTH-1:0]              dict_wr_code,
    input  logic [SYMBOL_WIDTH-1:0]           dict_wr_symbol,
    input  logic [4:0]                        dict_wr_len,
    output logic                              dict_cfg_error,

    input  logic [$clog2(NUM_TABLES)-1:0]     active_table,
    input  logic                              lookup_valid,
    output logic                              lookup_ready,
    input  logic [KEY_WIDTH-1:0]              lookup_bits,

    output logic                              result_valid,
    input  logic                              result_ready,
    output logic                              match_found,
    output logic [SYMBOL_WIDTH-1:0]           match_symbol,
    output logic [4:0]                        match_len
);

    logic [NUM_TABLES-1:0] bank_lookup_ready;
    logic [NUM_TABLES-1:0] bank_result_valid;
    logic [NUM_TABLES-1:0] bank_result_ready;
    logic [NUM_TABLES-1:0] bank_match_found;
    logic [SYMBOL_WIDTH-1:0] bank_match_symbol [0:NUM_TABLES-1];
    logic [4:0]              bank_match_len    [0:NUM_TABLES-1];

    // A zero length intentionally invalidates an entry and is legal. Table,
    // address, and nonzero length fields must otherwise be in range.
    always_comb begin
        dict_cfg_error = dict_wr_en
                       && ((dict_wr_table >= NUM_TABLES)
                           || (dict_wr_addr >= NUM_ENTRIES)
                           || (dict_wr_len > KEY_WIDTH));
    end

    generate
        for (genvar table_index = 0;
             table_index < NUM_TABLES;
             table_index++) begin : gen_table
            hardware_dictionary_accelerator #(
                .NUM_ENTRIES (NUM_ENTRIES),
                .KEY_WIDTH   (KEY_WIDTH),
                .SYMBOL_WIDTH(SYMBOL_WIDTH)
            ) matcher (
                .clk           (clk),
                .rst_n         (rst_n),
                .dict_wr_en    (dict_wr_en
                                && (dict_wr_table == table_index)),
                .dict_wr_addr  (dict_wr_addr),
                .dict_wr_code  (dict_wr_code),
                .dict_wr_symbol(dict_wr_symbol),
                .dict_wr_len   (dict_wr_len),
                .lookup_valid  (lookup_valid
                                && (active_table == table_index)),
                .lookup_ready  (bank_lookup_ready[table_index]),
                // Operand isolation keeps the large inactive CAM banks from
                // toggling as the active reservoir window changes.
                .lookup_bits   ((active_table == table_index)
                                ? lookup_bits : '0),
                .result_valid  (bank_result_valid[table_index]),
                .result_ready  (bank_result_ready[table_index]),
                .match_found   (bank_match_found[table_index]),
                .match_symbol  (bank_match_symbol[table_index]),
                .match_len     (bank_match_len[table_index])
            );

            assign bank_result_ready[table_index]
                = result_ready && (active_table == table_index);
        end
    endgenerate

    // Integration contract: active_table must remain unchanged from an
    // accepted lookup until its result is accepted. The simplified top obeys
    // this by changing active_table_q only on output_fire. With that contract,
    // this mux preserves ready/valid payload stability under backpressure.
    always_comb begin
        lookup_ready = 1'b0;
        result_valid = 1'b0;
        match_found  = 1'b0;
        match_symbol = '0;
        match_len    = '0;

        if (active_table < NUM_TABLES) begin
            lookup_ready = bank_lookup_ready[active_table];
            result_valid = bank_result_valid[active_table];
            match_found  = bank_match_found[active_table];
            match_symbol = bank_match_symbol[active_table];
            match_len    = bank_match_len[active_table];
        end
    end

endmodule
