// Complete benchmark-specific streaming wrapper for Huffman symbol lookup.
//
// Target: 200 MHz (5 ns clock), subject to implementation timing analysis.
// The feedback from a registered match to reservoir consumption gives this
// deliberately simple design an initiation interval of two clocks per symbol.

`timescale 1ns / 1ps

module huffman_find_simple_top #(
    parameter int NUM_TABLES    = 6,
    parameter int NUM_ENTRIES   = 147,
    parameter int KEY_WIDTH     = 16,
    parameter int SYMBOL_WIDTH  = 9,
    parameter int MAX_SELECTORS = 2966
)(
    input  logic                                  clk,
    // Assert asynchronously; deassert synchronously in the system wrapper.
    input  logic                                  rst_n,

    // Bus-independent configuration channels. cfg_ready is low while a job
    // is active; an MMIO adapter or testbench may drive these signals.
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

    // One start pulse begins one Huffman payload. Selector entries must be
    // programmed in ascending address order before start.
    input  logic                                  start,
    input  logic [2:0]                            start_bit,
    input  logic [$clog2(MAX_SELECTORS+1)-1:0]    selector_count,
    input  logic [SYMBOL_WIDTH-1:0]               eob_symbol,
    input  logic [31:0]                           symbol_capacity,

    // Eight-bit input stream, consumed MSB first within each byte.
    input  logic                                  byte_valid,
    output logic                                  byte_ready,
    input  logic [7:0]                            byte_data,
    input  logic                                  byte_last,

    // Registered, backpressure-safe decoded-symbol stream. EOB is emitted.
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

    // Register the active table so the selector-memory read is not in the
    // normal selector -> CAM compare -> priority -> result timing path.
    // The next selector is captured only at start or a 50-symbol boundary.
    logic [TABLE_WIDTH-1:0] active_table_q;
    logic                   active_table_valid_q;
    logic                   selector_current_valid;
    logic                   selector_write_good;
    logic                   selector_write_bad;

    logic                   matcher_lookup_valid;
    logic                   matcher_lookup_ready;
    logic                   matcher_result_valid;
    logic                   matcher_result_ready;
    logic                   matcher_found;
    logic [SYMBOL_WIDTH-1:0] matcher_symbol;
    logic [4:0]              matcher_len;
    logic                    dict_cfg_error;

    logic                   reservoir_clear;
    logic                   reservoir_peek_valid;
    logic [KEY_WIDTH-1:0]   reservoir_peek_bits;
    logic [5:0]             reservoir_valid_bits;
    logic                   reservoir_last_seen;
    logic                   reservoir_consume_valid;
    logic                   reservoir_consume_ready;
    logic                   output_fire;
    logic                   result_length_available;

    assign cfg_ready = !busy;

    assign selector_write_good = cfg_ready
                               && selector_wr_en
                               && (selector_wr_addr < MAX_SELECTORS)
                               && (selector_wr_table < NUM_TABLES)
                               && (selector_wr_addr
                                   <= selector_loaded_count_q);
    assign selector_write_bad = cfg_ready
                              && selector_wr_en
                              && !selector_write_good;

    assign selector_current_valid = active_table_valid_q
                                  && (selector_index_q < selector_count_q)
                                  && (selector_index_q < MAX_SELECTORS)
                                  && (active_table_q < NUM_TABLES);
    assign next_selector_index = selector_index_q + 1'b1;

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

    // Do not issue a new lookup while a registered result is pending. This
    // makes the bit-consumption feedback unambiguous and produces II=2. Under
    // this invariant the selected matcher's one-entry result register is empty,
    // so matcher_lookup_ready must be high whenever lookup_valid is asserted.
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

    // No-match and impossible-length results are consumed internally so they
    // cannot remain in a bank after the top level reports an error.
    always_comb begin
        matcher_result_ready = 1'b0;
        if (busy && matcher_result_valid) begin
            if (!matcher_found || !result_length_available
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
                // Rewrites below the frontier are allowed. New entries must
                // be contiguous so selector_count can prove they were loaded.
                if (selector_wr_addr == selector_loaded_count_q)
                    selector_loaded_count_q
                        <= selector_loaded_count_q + 1'b1;
            end else if (selector_write_bad) begin
                config_error_pending_q <= 1'b1;
            end

            if (!busy) begin
                if (start) begin
                    selector_index_q    <= '0;
                    symbols_in_group_q  <= '0;
                    active_table_q      <= '0;
                    active_table_valid_q <= 1'b0;
                    selector_count_q    <= selector_count;
                    eob_symbol_q        <= eob_symbol;
                    symbol_capacity_q   <= symbol_capacity;
                    bits_consumed       <= '0;
                    symbols_produced    <= '0;
                    cycle_count         <= '0;
                    input_stall_cycles  <= '0;
                    output_stall_cycles <= '0;
                    error               <= 1'b0;
                    error_code          <= ERR_NONE;
                    config_error_pending_q <= 1'b0;

                    if (config_error_pending_q
                            || dict_wr_en
                            || selector_wr_en
                            || (selector_count == 0)
                            || (selector_count > MAX_SELECTORS)
                            || (selector_count > selector_loaded_count_q)
                            || (eob_symbol >= NUM_ENTRIES)
                            || (symbol_capacity == 0)) begin
                        busy       <= 1'b0;
                        done       <= 1'b1;
                        error      <= 1'b1;
                        error_code <= ERR_BAD_CONFIG;
                    end else if (selector_mem[0] >= NUM_TABLES) begin
                        busy       <= 1'b0;
                        done       <= 1'b1;
                        error      <= 1'b1;
                        error_code <= ERR_SELECTOR;
                    end else begin
                        // Register table zero before decoding. This read and
                        // the initial reservoir fill occur in parallel.
                        active_table_q       <= selector_mem[0];
                        active_table_valid_q <= 1'b1;
                        busy                 <= 1'b1;
                    end
                end
            end else begin
                cycle_count <= cycle_count + 1'b1;

                // Input stalls count cycles when the reservoir could accept a
                // byte but the producer does not offer one.
                if (byte_ready && !byte_valid)
                    input_stall_cycles <= input_stall_cycles + 1'b1;
                if (symbol_valid && !symbol_ready)
                    output_stall_cycles <= output_stall_cycles + 1'b1;

                if (!selector_current_valid) begin
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    error      <= 1'b1;
                    error_code <= ERR_SELECTOR;
                    active_table_valid_q <= 1'b0;
                end else if (symbols_produced >= symbol_capacity_q) begin
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    error      <= 1'b1;
                    error_code <= ERR_OUTPUT_OVERFLOW;
                    active_table_valid_q <= 1'b0;
                end else if (matcher_result_valid && !matcher_found) begin
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    error      <= 1'b1;
                    // Once the final input byte has been seen, failure to
                    // complete a code is classified as truncated input.
                    error_code <= reservoir_last_seen
                                ? ERR_TRUNCATED : ERR_NO_SYMBOL;
                    active_table_valid_q <= 1'b0;
                end else if (matcher_result_valid
                             && !result_length_available) begin
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    error      <= 1'b1;
                    error_code <= ERR_TRUNCATED;
                    active_table_valid_q <= 1'b0;
                end else if (reservoir_last_seen
                             && !reservoir_peek_valid
                             && !matcher_result_valid) begin
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    error      <= 1'b1;
                    error_code <= ERR_TRUNCATED;
                    active_table_valid_q <= 1'b0;
                end else if (output_fire) begin
                    bits_consumed    <= bits_consumed + matcher_len;
                    symbols_produced <= symbols_produced + 1'b1;

                    if (symbol_eob) begin
                        busy                 <= 1'b0;
                        done                 <= 1'b1;
                        active_table_valid_q <= 1'b0;
                    end else if (symbols_in_group_q == 6'd49) begin
                        symbols_in_group_q <= '0;
                        if (next_selector_index >= selector_count_q) begin
                            busy       <= 1'b0;
                            done       <= 1'b1;
                            error      <= 1'b1;
                            error_code <= ERR_SELECTOR;
                            active_table_valid_q <= 1'b0;
                        end else if (selector_mem[next_selector_index]
                                     >= NUM_TABLES) begin
                            busy       <= 1'b0;
                            done       <= 1'b1;
                            error      <= 1'b1;
                            error_code <= ERR_SELECTOR;
                            active_table_valid_q <= 1'b0;
                        end else begin
                            selector_index_q <= next_selector_index;
                            // Capture the next table in a register at the
                            // group boundary. The following lookup therefore
                            // starts from registered selector state.
                            active_table_q <= selector_mem[next_selector_index];
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
