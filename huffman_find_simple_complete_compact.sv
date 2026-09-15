// Compact single-file version of the benchmark-specific pyflate accelerator.
//
// It preserves the same four module names, ports, parameters, hierarchy and
// behavior as huffman_find_simple_complete.sv. Compile ONE complete version,
// never both, because both files define the same modules.
//
// This version keeps comments only where behavior is not obvious and factors
// repeated terminal-error assignments into one synthesizable helper task.
// Ready/valid transfers occur on a rising edge when both signals are high.
// rst_n may assert asynchronously but must deassert synchronously outside the
// core. The 200 MHz (5 ns) clock is a target, not a proven implementation.

`timescale 1ns / 1ps

// =============================================================================
// One programmable CAM-style Huffman table
// =============================================================================
module hardware_dictionary_accelerator #(
    parameter int NUM_ENTRIES  = 147,
    parameter int KEY_WIDTH    = 16,
    parameter int SYMBOL_WIDTH = 9
)(
    input  logic                              clk,
    input  logic                              rst_n,

    input  logic                              dict_wr_en,
    input  logic [$clog2(NUM_ENTRIES)-1:0]    dict_wr_addr,
    input  logic [KEY_WIDTH-1:0]              dict_wr_code,
    input  logic [SYMBOL_WIDTH-1:0]           dict_wr_symbol,
    input  logic [4:0]                        dict_wr_len,

    input  logic                              lookup_valid,
    output logic                              lookup_ready,
    input  logic [KEY_WIDTH-1:0]              lookup_bits,

    output logic                              result_valid,
    input  logic                              result_ready,
    output logic                              match_found,
    output logic [SYMBOL_WIDTH-1:0]           match_symbol,
    output logic [4:0]                        match_len
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

    // Codes arrive right-aligned. Stored patterns and masks are MSB-aligned.
    // An out-of-range address is ignored; length zero invalidates an entry.
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

    // Synthesis expands this loop into NUM_ENTRIES parallel comparisons.
    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            raw_matches[i] = lookup_valid
                           && valid_mem[i]
                           && ((lookup_bits & mask_mem[i]) == pattern_mem[i]);
        end
    end

    // Shortest code wins; the lower entry index breaks equal-length ties.
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

    // One registered result slot; its payload holds while backpressured.
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

// =============================================================================
// Six resident Huffman tables and selected-bank routing
// =============================================================================
module huffman_find_six_table #(
    parameter int NUM_TABLES   = 6,
    parameter int NUM_ENTRIES  = 147,
    parameter int KEY_WIDTH    = 16,
    parameter int SYMBOL_WIDTH = 9
)(
    input  logic                              clk,
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

    assign dict_cfg_error = dict_wr_en
                          && ((dict_wr_table >= NUM_TABLES)
                              || (dict_wr_addr >= NUM_ENTRIES)
                              || (dict_wr_len > KEY_WIDTH));

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
                // Operand isolation reduces switching in inactive banks.
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

    // Guard dynamic indexing because the three-bit table ID also encodes 6,7.
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

// =============================================================================
// MSB-first byte-to-bit reservoir
// =============================================================================
module huffman_bit_reservoir #(
    parameter int BUFFER_WIDTH = 32,
    parameter int KEY_WIDTH    = 16
)(
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic                              active,
    input  logic                              clear,
    input  logic [2:0]                        start_bit,

    input  logic                              byte_valid,
    output logic                              byte_ready,
    input  logic [7:0]                        byte_data,
    input  logic                              byte_last,

    input  logic                              consume_valid,
    output logic                              consume_ready,
    input  logic [4:0]                        consume_len,

    output logic                              peek_valid,
    output logic [KEY_WIDTH-1:0]              peek_bits,
    output logic [$clog2(BUFFER_WIDTH+1)-1:0] valid_bits,
    output logic                              input_last_seen
);

    localparam int COUNT_WIDTH = $clog2(BUFFER_WIDTH + 1);

    logic [BUFFER_WIDTH-1:0] buffer_q;
    logic [BUFFER_WIDTH-1:0] buffer_n;
    logic [COUNT_WIDTH-1:0]  bit_count_q;
    logic [COUNT_WIDTH-1:0]  bit_count_n;
    logic [COUNT_WIDTH-1:0]  count_after_consume;
    logic [2:0]              start_bit_q;
    logic                    first_byte_q;
    logic                    input_last_q;
    logic                    consume_fire;
    logic                    byte_fire;
    logic [BUFFER_WIDTH-1:0] byte_word;

    assign peek_bits       = buffer_q[BUFFER_WIDTH-1 -: KEY_WIDTH];
    assign peek_valid      = active
                           && ((bit_count_q >= KEY_WIDTH)
                               || (input_last_q && (bit_count_q != 0)));
    assign valid_bits      = bit_count_q;
    assign input_last_seen = input_last_q;

    assign consume_ready = active
                         && (consume_len != 0)
                         && (consume_len <= bit_count_q);
    assign consume_fire = consume_valid && consume_ready;

    // Capacity is calculated after a possible consume, allowing refill on the
    // same edge. Keeping this procedural form preserves four-state behavior.
    always_comb begin
        count_after_consume = bit_count_q;
        if (consume_fire)
            count_after_consume = bit_count_q - consume_len;

        byte_ready = active
                   && !input_last_q
                   && (count_after_consume <= (BUFFER_WIDTH - 8));
    end

    assign byte_fire = byte_valid && byte_ready;
    assign byte_word = {{(BUFFER_WIDTH-8){1'b0}}, byte_data};

    // Next state always consumes first and appends a transferred byte second.
    always_comb begin
        buffer_n    = buffer_q;
        bit_count_n = bit_count_q;

        if (consume_fire) begin
            buffer_n    = buffer_n << consume_len;
            bit_count_n = bit_count_n - consume_len;
        end

        if (byte_fire) begin
            if (first_byte_q) begin
                buffer_n = byte_word
                         << (BUFFER_WIDTH - 8 + start_bit_q);
                bit_count_n = 8 - start_bit_q;
            end else begin
                buffer_n = buffer_n
                         | (byte_word
                            << (BUFFER_WIDTH - 8 - bit_count_n));
                bit_count_n = bit_count_n + 8;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer_q     <= '0;
            bit_count_q  <= '0;
            start_bit_q  <= '0;
            first_byte_q <= 1'b1;
            input_last_q <= 1'b0;
        end else if (clear) begin
            buffer_q     <= '0;
            bit_count_q  <= '0;
            start_bit_q  <= start_bit;
            first_byte_q <= 1'b1;
            input_last_q <= 1'b0;
        end else if (active) begin
            buffer_q    <= buffer_n;
            bit_count_q <= bit_count_n;

            if (byte_fire) begin
                first_byte_q <= 1'b0;
                if (byte_last)
                    input_last_q <= 1'b1;
            end
        end
    end

endmodule

// =============================================================================
// Complete streaming accelerator
// =============================================================================
module huffman_find_simple_top #(
    parameter int NUM_TABLES    = 6,
    parameter int NUM_ENTRIES   = 147,
    parameter int KEY_WIDTH     = 16,
    parameter int SYMBOL_WIDTH  = 9,
    parameter int MAX_SELECTORS = 2966
)(
    input  logic                                  clk,
    input  logic                                  rst_n,

    output logic                                  cfg_ready,
    input  logic                                  dict_wr_en,
    input  logic [$clog2(NUM_TABLES)-1:0]         dict_wr_table,
    input  logic [$clog2(NUM_ENTRIES)-1:0]        dict_wr_addr,
    input  logic [KEY_WIDTH-1:0]                  dict_wr_code,
    input  logic [SYMBOL_WIDTH-1:0]               dict_wr_symbol,
    input  logic [4:0]                            dict_wr_len,
    input  logic                                  selector_wr_en,
    input  logic [$clog2(MAX_SELECTORS)-1:0]      selector_wr_addr,
    input  logic [$clog2(NUM_TABLES)-1:0]         selector_wr_table,

    input  logic                                  start,
    input  logic [2:0]                            start_bit,
    input  logic [$clog2(MAX_SELECTORS+1)-1:0]    selector_count,
    input  logic [SYMBOL_WIDTH-1:0]               eob_symbol,
    input  logic [31:0]                           symbol_capacity,

    input  logic                                  byte_valid,
    output logic                                  byte_ready,
    input  logic [7:0]                            byte_data,
    input  logic                                  byte_last,

    output logic                                  symbol_valid,
    input  logic                                  symbol_ready,
    output logic [SYMBOL_WIDTH-1:0]               symbol,
    output logic [4:0]                            code_length,
    output logic [$clog2(NUM_TABLES)-1:0]         table_id,
    output logic                                  symbol_eob,

    output logic                                  busy,
    output logic                                  done,
    output logic                                  error,
    output logic [7:0]                            error_code,
    output logic [31:0]                           bits_consumed,
    output logic [31:0]                           symbols_produced,
    output logic [63:0]                           cycle_count,
    output logic [31:0]                           input_stall_cycles,
    output logic [31:0]                           output_stall_cycles
);

    localparam int TABLE_WIDTH    = $clog2(NUM_TABLES);
    localparam int SELECTOR_WIDTH = $clog2(MAX_SELECTORS);
    localparam int COUNT_WIDTH    = $clog2(MAX_SELECTORS + 1);

    localparam logic [7:0] ERR_NONE            = 8'h00;
    localparam logic [7:0] ERR_BAD_CONFIG      = 8'h02;
    localparam logic [7:0] ERR_TRUNCATED       = 8'h04;
    localparam logic [7:0] ERR_NO_SYMBOL       = 8'h05;
    localparam logic [7:0] ERR_SELECTOR        = 8'h06;
    localparam logic [7:0] ERR_OUTPUT_OVERFLOW = 8'h07;

    logic [TABLE_WIDTH-1:0] selector_mem [0:MAX_SELECTORS-1];
    logic [COUNT_WIDTH-1:0] selector_loaded_count_q;
    logic [COUNT_WIDTH-1:0] selector_index_q;
    logic [COUNT_WIDTH-1:0] next_selector_index;
    logic [5:0]             symbols_in_group_q;
    logic [COUNT_WIDTH-1:0] selector_count_q;
    logic [SYMBOL_WIDTH-1:0] eob_symbol_q;
    logic [31:0]             symbol_capacity_q;
    logic                    config_error_pending_q;

    logic [TABLE_WIDTH-1:0] active_table_q;
    logic                   active_table_valid_q;
    logic                   selector_current_valid;
    logic                   selector_write_good;
    logic                   selector_write_bad;
    logic                   start_bad_config;

    logic                    matcher_lookup_valid;
    logic                    matcher_lookup_ready;
    logic                    matcher_result_valid;
    logic                    matcher_result_ready;
    logic                    matcher_found;
    logic [SYMBOL_WIDTH-1:0] matcher_symbol;
    logic [4:0]              matcher_len;
    logic                    dict_cfg_error;

    logic                 reservoir_clear;
    logic                 reservoir_peek_valid;
    logic [KEY_WIDTH-1:0] reservoir_peek_bits;
    logic [5:0]           reservoir_valid_bits;
    logic                 reservoir_last_seen;
    logic                 reservoir_consume_valid;
    logic                 reservoir_consume_ready;
    logic                 output_fire;
    logic                 result_length_available;

    // This task only groups repeated nonblocking assignments. Calls still sit
    // in the original ordered if/else chain, so error priority is unchanged.
    task automatic finish_error(input logic [7:0] code);
        begin
            busy                 <= 1'b0;
            done                 <= 1'b1;
            error                <= 1'b1;
            error_code           <= code;
            active_table_valid_q <= 1'b0;
        end
    endtask

    assign cfg_ready = !busy;

    assign selector_write_good = cfg_ready
                               && selector_wr_en
                               && (selector_wr_addr < MAX_SELECTORS)
                               && (selector_wr_table < NUM_TABLES)
                               && (selector_wr_addr <= selector_loaded_count_q);
    assign selector_write_bad = cfg_ready
                              && selector_wr_en
                              && !selector_write_good;

    assign selector_current_valid = active_table_valid_q
                                  && (selector_index_q < selector_count_q)
                                  && (selector_index_q < MAX_SELECTORS)
                                  && (active_table_q < NUM_TABLES);
    assign next_selector_index = selector_index_q + 1'b1;

    assign start_bad_config = config_error_pending_q
                            || dict_wr_en
                            || selector_wr_en
                            || (selector_count == 0)
                            || (selector_count > MAX_SELECTORS)
                            || (selector_count > selector_loaded_count_q)
                            || (eob_symbol >= NUM_ENTRIES)
                            || (symbol_capacity == 0);

    assign reservoir_clear = !busy && start;

    huffman_bit_reservoir #(
        .BUFFER_WIDTH(32),
        .KEY_WIDTH   (KEY_WIDTH)
    ) reservoir (
        .clk            (clk),
        .rst_n          (rst_n),
        .active         (busy),
        .clear          (reservoir_clear),
        .start_bit      (start_bit),
        .byte_valid     (byte_valid),
        .byte_ready     (byte_ready),
        .byte_data      (byte_data),
        .byte_last      (byte_last),
        .consume_valid  (reservoir_consume_valid),
        .consume_ready  (reservoir_consume_ready),
        .consume_len    (matcher_len),
        .peek_valid     (reservoir_peek_valid),
        .peek_bits      (reservoir_peek_bits),
        .valid_bits     (reservoir_valid_bits),
        .input_last_seen(reservoir_last_seen)
    );

    // One outstanding result keeps bit-consumption feedback unambiguous (II=2).
    assign matcher_lookup_valid = busy
                                && selector_current_valid
                                && reservoir_peek_valid
                                && !matcher_result_valid
                                && (symbols_produced < symbol_capacity_q);

    huffman_find_six_table #(
        .NUM_TABLES  (NUM_TABLES),
        .NUM_ENTRIES (NUM_ENTRIES),
        .KEY_WIDTH   (KEY_WIDTH),
        .SYMBOL_WIDTH(SYMBOL_WIDTH)
    ) tables (
        .clk           (clk),
        .rst_n         (rst_n),
        .dict_wr_en    (dict_wr_en && cfg_ready),
        .dict_wr_table (dict_wr_table),
        .dict_wr_addr  (dict_wr_addr),
        .dict_wr_code  (dict_wr_code),
        .dict_wr_symbol(dict_wr_symbol),
        .dict_wr_len   (dict_wr_len),
        .dict_cfg_error(dict_cfg_error),
        .active_table  (active_table_q),
        .lookup_valid  (matcher_lookup_valid),
        .lookup_ready  (matcher_lookup_ready),
        .lookup_bits   (reservoir_peek_bits),
        .result_valid  (matcher_result_valid),
        .result_ready  (matcher_result_ready),
        .match_found   (matcher_found),
        .match_symbol  (matcher_symbol),
        .match_len     (matcher_len)
    );

    assign result_length_available = matcher_len <= reservoir_valid_bits;

    assign symbol_valid = busy
                        && selector_current_valid
                        && matcher_result_valid
                        && matcher_found
                        && result_length_available
                        && (symbols_produced < symbol_capacity_q);
    assign symbol        = matcher_symbol;
    assign code_length   = matcher_len;
    assign table_id      = active_table_q;
    assign symbol_eob    = symbol_valid && (matcher_symbol == eob_symbol_q);

    assign reservoir_consume_valid = symbol_valid && symbol_ready;
    assign output_fire = reservoir_consume_valid && reservoir_consume_ready;

    // Invalid results are drained internally, independent of symbol_ready.
    always_comb begin
        matcher_result_ready = 1'b0;
        if (busy && matcher_result_valid) begin
            if (!matcher_found
                    || !result_length_available
                    || (symbols_produced >= symbol_capacity_q))
                matcher_result_ready = 1'b1;
            else
                matcher_result_ready = output_fire;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            selector_loaded_count_q <= '0;
            selector_index_q        <= '0;
            symbols_in_group_q      <= '0;
            active_table_q          <= '0;
            active_table_valid_q    <= 1'b0;
            selector_count_q        <= '0;
            eob_symbol_q            <= '0;
            symbol_capacity_q       <= '0;
            config_error_pending_q  <= 1'b0;
            busy                    <= 1'b0;
            done                    <= 1'b0;
            error                   <= 1'b0;
            error_code              <= ERR_NONE;
            bits_consumed           <= '0;
            symbols_produced        <= '0;
            cycle_count             <= '0;
            input_stall_cycles      <= '0;
            output_stall_cycles     <= '0;
        end else begin
            done <= 1'b0;

            if (dict_cfg_error)
                config_error_pending_q <= 1'b1;

            if (selector_write_good) begin
                selector_mem[selector_wr_addr] <= selector_wr_table;
                if (selector_wr_addr == selector_loaded_count_q)
                    selector_loaded_count_q
                        <= selector_loaded_count_q + 1'b1;
            end else if (selector_write_bad) begin
                config_error_pending_q <= 1'b1;
            end

            if (!busy) begin
                if (start) begin
                    selector_index_q     <= '0;
                    symbols_in_group_q   <= '0;
                    active_table_q       <= '0;
                    active_table_valid_q <= 1'b0;
                    selector_count_q     <= selector_count;
                    eob_symbol_q         <= eob_symbol;
                    symbol_capacity_q    <= symbol_capacity;
                    bits_consumed        <= '0;
                    symbols_produced     <= '0;
                    cycle_count          <= '0;
                    input_stall_cycles   <= '0;
                    output_stall_cycles  <= '0;
                    error                <= 1'b0;
                    error_code           <= ERR_NONE;
                    config_error_pending_q <= 1'b0;

                    if (start_bad_config) begin
                        finish_error(ERR_BAD_CONFIG);
                    end else if (selector_mem[0] >= NUM_TABLES) begin
                        finish_error(ERR_SELECTOR);
                    end else begin
                        active_table_q       <= selector_mem[0];
                        active_table_valid_q <= 1'b1;
                        busy                 <= 1'b1;
                    end
                end
            end else begin
                cycle_count <= cycle_count + 1'b1;

                if (byte_ready && !byte_valid)
                    input_stall_cycles <= input_stall_cycles + 1'b1;
                if (symbol_valid && !symbol_ready)
                    output_stall_cycles <= output_stall_cycles + 1'b1;

                // Order is intentional and matches the documented design.
                if (!selector_current_valid) begin
                    finish_error(ERR_SELECTOR);
                end else if (symbols_produced >= symbol_capacity_q) begin
                    finish_error(ERR_OUTPUT_OVERFLOW);
                end else if (matcher_result_valid && !matcher_found) begin
                    finish_error(reservoir_last_seen
                                 ? ERR_TRUNCATED : ERR_NO_SYMBOL);
                end else if (matcher_result_valid
                             && !result_length_available) begin
                    finish_error(ERR_TRUNCATED);
                end else if (reservoir_last_seen
                             && !reservoir_peek_valid
                             && !matcher_result_valid) begin
                    finish_error(ERR_TRUNCATED);
                end else if (output_fire) begin
                    bits_consumed    <= bits_consumed + matcher_len;
                    symbols_produced <= symbols_produced + 1'b1;

                    // EOB wins over a selector boundary and is still emitted.
                    if (symbol_eob) begin
                        busy                 <= 1'b0;
                        done                 <= 1'b1;
                        active_table_valid_q <= 1'b0;
                    end else if (symbols_in_group_q == 6'd49) begin
                        symbols_in_group_q <= '0;

                        // Do not read selector_mem until the index is proven.
                        if (next_selector_index >= selector_count_q) begin
                            finish_error(ERR_SELECTOR);
                        end else if (selector_mem[next_selector_index]
                                     >= NUM_TABLES) begin
                            finish_error(ERR_SELECTOR);
                        end else begin
                            selector_index_q <= next_selector_index;
                            active_table_q
                                <= selector_mem[next_selector_index];
                        end
                    end else begin
                        symbols_in_group_q
                            <= symbols_in_group_q + 1'b1;
                    end
                end
            end
        end
    end

endmodule
