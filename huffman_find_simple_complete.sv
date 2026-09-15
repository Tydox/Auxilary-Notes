// ============================================================================
// Pyflate benchmark-specific Huffman accelerator: complete single-file version
// ============================================================================
//
// PURPOSE
// -------
// This proof-of-concept source packages the complete active simplified design
// into one SystemVerilog file. It contains four modules while preserving their
// hierarchy and behavior:
//
//   huffman_find_simple_top
//   |-- huffman_bit_reservoir
//   `-- huffman_find_six_table
//       `-- 6 x hardware_dictionary_accelerator
//
// BUILD RULE
// ----------
// Compile this file INSTEAD OF the four split source files. Compiling both this
// file and the split files together will cause duplicate module definitions.
// See ../HUFFMAN_FIND_SIMPLE_COMPLETE_GUIDE.md for interface tables, diagrams,
// equations, and a suggested beginner reading order.
//
// The original source comments are retained below. Additional explanatory
// comments identify the purpose of parameters, ports, registered state, and
// combinational helper signals. This is a course proof of concept, not a claim
// of synthesis, timing closure, or tapeout readiness.
//
// NAMING CONVENTION
// -----------------
// Names ending in _q are values held in registers. Names ending in _n are
// combinational next-state values. Names ending in _fire identify a transfer
// that really happens because both ready and valid are high on that cycle.
// ============================================================================

// ============================================================================
// BEGIN ORIGINAL MODULE SOURCE: huffman_find_simple.sv
// ============================================================================

// Simplified CAM-style Huffman matcher for the measured pyflate workload.
//
// This is the one-table core. It stores one Huffman table and matches a
// 16-bit, MSB-first lookup window. huffman_find_six_table places six instances
// behind a selector, and huffman_find_simple_top adds the streaming reservoir.

// Simulation times are expressed in nanoseconds with picosecond precision.
// This directive does not set the synthesized circuit's clock frequency.
`timescale 1ns / 1ps

module hardware_dictionary_accelerator #(
    parameter int NUM_ENTRIES  = 147, // Number of programmable code/symbol entries in this one table.
    parameter int KEY_WIDTH    = 16,  // Width of the MSB-first lookup window, stored pattern, and mask.
    parameter int SYMBOL_WIDTH = 9    // Width of one decoded Huffman symbol.
)(
    input  logic                     clk,          // Clock for configuration and result registers.
    // Asynchronous assertion is supported. The system wrapper must synchronize
    // deassertion to clk so every register leaves reset on a safe clock edge.
    input  logic                     rst_n,        // Active-low reset; clears entry-valid bits and result state.

    // Dictionary programming interface. dict_wr_code is a right-aligned
    // canonical code; the core derives the MSB-aligned pattern and mask.
    input  logic                     dict_wr_en,     // High for one cycle to program or invalidate one entry.
    input  logic [$clog2(NUM_ENTRIES)-1:0] dict_wr_addr, // Index of the table entry being written.
    input  logic [KEY_WIDTH-1:0]     dict_wr_code,   // Right-aligned canonical Huffman code supplied by software.
    input  logic [SYMBOL_WIDTH-1:0]  dict_wr_symbol, // Decoded symbol associated with dict_wr_code.
    input  logic [4:0]               dict_wr_len,    // Code length in bits; zero invalidates the addressed entry.

    // Lookup request channel. lookup_bits[KEY_WIDTH-1] is the next compressed
    // bit. A request transfers only when valid and ready are both high.
    input  logic                     lookup_valid, // Producer asserts this when lookup_bits contains a request.
    output logic                     lookup_ready, // Matcher can accept a request when its result register is free.
    input  logic [KEY_WIDTH-1:0]     lookup_bits,  // Next compressed bits, with the next bit at the MSB.

    // Registered result channel. A no-match lookup is still a valid result.
    output logic                     result_valid, // Registered result is present, including a no-match result.
    input  logic                     result_ready, // Consumer can accept the registered result this cycle.
    output logic                     match_found,  // One or more valid table entries matched lookup_bits.
    output logic [SYMBOL_WIDTH-1:0]  match_symbol, // Decoded symbol selected by the priority logic.
    output logic [4:0]               match_len     // Number of compressed bits belonging to match_symbol.
);

    // Dictionary Storage Elements
    logic [KEY_WIDTH-1:0]    pattern_mem [0:NUM_ENTRIES-1]; // MSB-aligned code pattern for each entry.
    logic [KEY_WIDTH-1:0]    mask_mem    [0:NUM_ENTRIES-1]; // Ones mark the prefix bits compared for each entry.
    logic [SYMBOL_WIDTH-1:0] symbol_mem  [0:NUM_ENTRIES-1]; // Decoded symbol stored in each entry.
    logic [4:0]              len_mem     [0:NUM_ENTRIES-1]; // Valid Huffman-code length stored in each entry.
    logic [NUM_ENTRIES-1:0]  valid_mem;                     // One bit per entry: one means the entry may match.

    logic [NUM_ENTRIES-1:0]  raw_matches;      // Parallel match bit produced by every table entry.
    logic                    candidate_found;  // Combinational flag indicating that priority search found a match.
    logic [SYMBOL_WIDTH-1:0] candidate_symbol; // Combinational symbol chosen shortest-length-first.
    logic [4:0]              candidate_len;    // Combinational code length belonging to candidate_symbol.

    // The four data arrays do not need reset values. valid_mem resets to zero,
    // so unknown data in every unconfigured slot is prevented from matching.

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
        // i identifies an entry while describing NUM_ENTRIES parallel masked
        // comparators; it is a synthesis loop, not a sequential runtime scan.
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

        // l visits code lengths from shortest to longest. For equal lengths,
        // i visits entry addresses in ascending order as a deterministic tie.
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

// ============================================================================
// END ORIGINAL MODULE SOURCE: huffman_find_simple.sv
// ============================================================================

// ============================================================================
// BEGIN ORIGINAL MODULE SOURCE: huffman_find_six_table.sv
// ============================================================================

// Six-bank wrapper around the Section 1 CAM matcher.
// Only the selected bank receives lookup_valid, which suppresses unnecessary
// switching in the other five banks. All six tables remain immediately
// available, so a bzip2 selector change does not require reprogramming.

`timescale 1ns / 1ps

module huffman_find_six_table #(
    parameter int NUM_TABLES   = 6,   // Number of physical Huffman table banks instantiated below.
    parameter int NUM_ENTRIES  = 147, // Number of code/symbol entries in every bank.
    parameter int KEY_WIDTH    = 16,  // Width of the lookup prefix sent to the selected bank.
    parameter int SYMBOL_WIDTH = 9    // Width of a decoded symbol returned by a bank.
)(
    input  logic                              clk,           // Shared clock for all six matcher banks.
    // Assert asynchronously; deassert synchronously in the system wrapper.
    input  logic                              rst_n,         // Active-low reset shared by every bank.

    input  logic                              dict_wr_en,     // Requests a configuration write to one selected bank.
    input  logic [$clog2(NUM_TABLES)-1:0]     dict_wr_table,  // Bank number receiving the configuration write.
    input  logic [$clog2(NUM_ENTRIES)-1:0]    dict_wr_addr,   // Entry number within dict_wr_table.
    input  logic [KEY_WIDTH-1:0]              dict_wr_code,   // Right-aligned Huffman code written into that entry.
    input  logic [SYMBOL_WIDTH-1:0]           dict_wr_symbol, // Decoded symbol written into that entry.
    input  logic [4:0]                        dict_wr_len,    // Code length; zero intentionally invalidates an entry.
    output logic                              dict_cfg_error, // High when an asserted configuration write is out of range.

    input  logic [$clog2(NUM_TABLES)-1:0]     active_table, // Bank used for the current lookup and result.
    input  logic                              lookup_valid, // Lookup request for active_table is valid.
    output logic                              lookup_ready, // Selected bank can accept the lookup request.
    input  logic [KEY_WIDTH-1:0]              lookup_bits,  // MSB-first compressed-bit window sent to the selected bank.

    output logic                              result_valid, // Selected bank has a registered result available.
    input  logic                              result_ready, // Top level is accepting that selected result.
    output logic                              match_found,  // Selected bank found a valid Huffman entry.
    output logic [SYMBOL_WIDTH-1:0]           match_symbol, // Symbol returned by the selected bank.
    output logic [4:0]                        match_len     // Code length returned by the selected bank.
);

    logic [NUM_TABLES-1:0] bank_lookup_ready; // Per-bank ready outputs; only active_table is observed.
    logic [NUM_TABLES-1:0] bank_result_valid; // Per-bank registered-result valid bits.
    logic [NUM_TABLES-1:0] bank_result_ready; // One-hot ready feedback sent only to active_table.
    logic [NUM_TABLES-1:0] bank_match_found;  // Per-bank indication of match versus no-match.
    logic [SYMBOL_WIDTH-1:0] bank_match_symbol [0:NUM_TABLES-1]; // Decoded symbol output from each bank.
    logic [4:0]              bank_match_len    [0:NUM_TABLES-1]; // Decoded code length output from each bank.

    // A zero length intentionally invalidates an entry and is legal. Table,
    // address, and nonzero length fields must otherwise be in range.
    // dict_cfg_error reports the problem to the top; the one-table matcher also
    // contains the actual bounds checks that prevent an unsafe array access.
    always_comb begin
        dict_cfg_error = dict_wr_en
                       && ((dict_wr_table >= NUM_TABLES)
                           || (dict_wr_addr >= NUM_ENTRIES)
                           || (dict_wr_len > KEY_WIDTH));
    end

    generate
        // table_index is a compile-time generate index; synthesis creates one
        // real matcher instance and one set of routing wires for each value.
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

// ============================================================================
// END ORIGINAL MODULE SOURCE: huffman_find_six_table.sv
// ============================================================================

// ============================================================================
// BEGIN ORIGINAL MODULE SOURCE: huffman_bit_reservoir.sv
// ============================================================================

// 32-bit MSB-first byte-to-bit reservoir for the simplified pyflate design.
// Valid bits are always left aligned; peek_bits[15] is the next bit decoded.

`timescale 1ns / 1ps

module huffman_bit_reservoir #(
    parameter int BUFFER_WIDTH = 32, // Total number of compressed bits retained in the reservoir.
    parameter int KEY_WIDTH    = 16  // Number of leading bits exposed to the Huffman matcher.
)(
    input  logic                         clk,       // Clock for all reservoir state registers.
    // Assert asynchronously; deassert synchronously in the system wrapper.
    input  logic                         rst_n,     // Active-low reset for buffer, count, and stream-position state.
    input  logic                         active,    // Enables normal consume/refill operation while a job is busy.
    input  logic                         clear,     // Starts a new payload and latches start_bit into start_bit_q.
    input  logic [2:0]                   start_bit, // Number of leading bits, 0 through 7, skipped in the first byte.

    input  logic                         byte_valid, // Input producer is presenting a valid compressed byte.
    output logic                         byte_ready, // Reservoir has room to accept that byte this cycle.
    input  logic [7:0]                   byte_data,  // Compressed byte; bit 7 is consumed before bit 6, and so on.
    input  logic                         byte_last,  // Marks byte_data as the final byte of the current payload.

    input  logic                         consume_valid, // Controller requests removal of a decoded code prefix.
    output logic                         consume_ready, // Requested nonzero length is currently present and removable.
    input  logic [4:0]                   consume_len,   // Number of valid leading bits to remove after symbol acceptance.

    output logic                         peek_valid, // A full window, or legal final partial window, may be examined.
    output logic [KEY_WIDTH-1:0]         peek_bits,  // Next KEY_WIDTH bits in MSB-first order; final padding may be zero.
    output logic [$clog2(BUFFER_WIDTH+1)-1:0] valid_bits, // Number of real, non-padding bits held in buffer_q.
    output logic                         input_last_seen // The accepted input stream has already supplied byte_last.
);

    localparam int COUNT_WIDTH = $clog2(BUFFER_WIDTH + 1); // Bits needed to count every occupancy from 0 to BUFFER_WIDTH.

    logic [BUFFER_WIDTH-1:0] buffer_q; // Registered left-aligned reservoir contents currently in use.
    logic [BUFFER_WIDTH-1:0] buffer_n; // Combinational next buffer after consume first and optional refill second.
    logic [COUNT_WIDTH-1:0]  bit_count_q; // Registered number of real valid bits in buffer_q.
    logic [COUNT_WIDTH-1:0]  bit_count_n; // Next valid-bit count corresponding to buffer_n.
    logic [COUNT_WIDTH-1:0]  count_after_consume; // Predicted occupancy used to decide whether a new byte fits.
    logic [2:0]              start_bit_q; // Registered first-byte offset captured when clear is asserted.
    logic                    first_byte_q; // One until the first input byte has been accepted and aligned.
    logic                    input_last_q; // Sticky register set after accepting a byte marked byte_last.
    logic                    consume_fire; // Handshake event: consume_valid and consume_ready are both high.
    logic                    byte_fire;    // Handshake event: byte_valid and byte_ready are both high.
    logic [BUFFER_WIDTH-1:0] byte_word;    // byte_data zero-extended to BUFFER_WIDTH before alignment and insertion.

    assign peek_bits       = buffer_q[BUFFER_WIDTH-1 -: KEY_WIDTH];
    // Before the last byte, wait for a complete lookup window. After byte_last,
    // expose a zero-padded partial window; the top level rejects any returned
    // code length greater than valid_bits, so a final short EOB is supported
    // without accepting a match made from padding.
    assign peek_valid      = active
                           && ((bit_count_q >= KEY_WIDTH)
                               || (input_last_q && (bit_count_q != 0)));
    assign valid_bits      = bit_count_q;
    assign input_last_seen = input_last_q;

    assign consume_ready = active
                         && (consume_len != 0)
                         && (consume_len <= bit_count_q);
    assign consume_fire = consume_valid && consume_ready;

    always_comb begin
        count_after_consume = bit_count_q;
        if (consume_fire)
            count_after_consume = bit_count_q - consume_len;

        // One new byte fits when no more than 24 bits remain. Consumption is
        // considered first, allowing consume and refill on the same edge.
        byte_ready = active
                   && !input_last_q
                   && (count_after_consume <= (BUFFER_WIDTH - 8));
    end

    assign byte_fire = byte_valid && byte_ready;
    assign byte_word = {{(BUFFER_WIDTH-8){1'b0}}, byte_data};

    always_comb begin
        buffer_n    = buffer_q;
        bit_count_n = bit_count_q;

        if (consume_fire) begin
            buffer_n    = buffer_n << consume_len;
            bit_count_n = bit_count_n - consume_len;
        end

        if (byte_fire) begin
            if (first_byte_q) begin
                // Discard start_bit leading bits from the first byte, then
                // left-align the remaining 1 through 8 bits.
                buffer_n = byte_word
                         << (BUFFER_WIDTH - 8 + start_bit_q);
                bit_count_n = 8 - start_bit_q;
            end else begin
                // Existing bits occupy the MSB side. Append the new byte
                // immediately below them without disturbing their order.
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

// ============================================================================
// END ORIGINAL MODULE SOURCE: huffman_bit_reservoir.sv
// ============================================================================

// ============================================================================
// BEGIN ORIGINAL MODULE SOURCE: huffman_find_simple_top.sv
// ============================================================================

// Complete benchmark-specific streaming wrapper for Huffman symbol lookup.
//
// Target: 200 MHz (5 ns clock), subject to implementation timing analysis.
// The feedback from a registered match to reservoir consumption gives this
// deliberately simple design an initiation interval of two clocks per symbol.

`timescale 1ns / 1ps

module huffman_find_simple_top #(
    parameter int NUM_TABLES    = 6,    // Physical Huffman banks; six is the bzip2 benchmark maximum.
    parameter int NUM_ENTRIES   = 147,  // Entries per bank for this workload; general bzip2 can require 258.
    parameter int KEY_WIDTH     = 16,   // Lookup width and maximum supported code length for this benchmark build.
    parameter int SYMBOL_WIDTH  = 9,    // Width of decoded symbol identifiers and the configured EOB value.
    parameter int MAX_SELECTORS = 2966  // Maximum stored schedule entries, one per group of up to 50 symbols.
)(
    input  logic                                  clk,       // Clock for the complete accelerator and all submodules.
    // Assert asynchronously; deassert synchronously in the system wrapper.
    input  logic                                  rst_n,     // Active-low reset; deassert synchronously in the wrapper.

    // Bus-independent configuration channels. cfg_ready is low while a job
    // is active; an MMIO adapter or testbench may drive these signals.
    output logic                                  cfg_ready,         // High while idle, when configuration writes are allowed.
    input  logic                                  dict_wr_en,        // Strobe to program/invalidate one Huffman table entry.
    input  logic [$clog2(NUM_TABLES)-1:0]         dict_wr_table,     // ID of the table bank being programmed.
    input  logic [$clog2(NUM_ENTRIES)-1:0]        dict_wr_addr,      // Entry index inside dict_wr_table.
    input  logic [KEY_WIDTH-1:0]                  dict_wr_code,      // Right-aligned canonical Huffman code.
    input  logic [SYMBOL_WIDTH-1:0]               dict_wr_symbol,    // Decoded symbol associated with dict_wr_code.
    input  logic [4:0]                            dict_wr_len,       // Huffman code length; zero invalidates this entry.
    input  logic                                  selector_wr_en,    // Strobe to write one selector schedule entry.
    input  logic [$clog2(MAX_SELECTORS)-1:0]      selector_wr_addr,  // Selector index, programmed as a contiguous prefix.
    input  logic [$clog2(NUM_TABLES)-1:0]         selector_wr_table, // Table ID used by the corresponding 50-symbol group.

    // One start pulse begins one Huffman payload. Selector entries must be
    // programmed in ascending address order before start.
    input  logic                                  start,           // One-cycle request to begin decoding one payload.
    input  logic [2:0]                            start_bit,       // Leading-bit offset, 0..7, in the first source byte.
    input  logic [$clog2(MAX_SELECTORS+1)-1:0]    selector_count,  // Number of valid selector entries for this job.
    input  logic [SYMBOL_WIDTH-1:0]               eob_symbol,      // Decoded value that terminates this Huffman block.
    input  logic [31:0]                           symbol_capacity, // Maximum accepted outputs, including EOB.

    // Eight-bit input stream, consumed MSB first within each byte.
    input  logic                                  byte_valid, // Producer asserts when byte_data and byte_last are meaningful.
    output logic                                  byte_ready, // Reservoir has room to accept the offered source byte.
    input  logic [7:0]                            byte_data,  // Next compressed source byte, consumed MSB first.
    input  logic                                  byte_last,  // Marks the transferred byte as the final source byte.

    // Registered, backpressure-safe decoded-symbol stream. EOB is emitted.
    output logic                                  symbol_valid, // A decoded output and its metadata are ready to transfer.
    input  logic                                  symbol_ready, // Consumer readiness; low applies output backpressure.
    output logic [SYMBOL_WIDTH-1:0]               symbol,       // Decoded Huffman symbol from the active table.
    output logic [4:0]                            code_length,  // Compressed bits consumed for this symbol.
    output logic [$clog2(NUM_TABLES)-1:0]         table_id,     // Table bank that decoded this symbol.
    output logic                                  symbol_eob,   // High when the valid symbol equals the configured EOB.

    output logic                                  busy,                // High from an accepted valid start until EOB or error.
    output logic                                  done,                // One-cycle pulse on successful or failed completion.
    output logic                                  error,               // Latched indication that the current/last job failed.
    output logic [7:0]                            error_code,          // Encoded terminal failure reason, or ERR_NONE.
    output logic [31:0]                           bits_consumed,       // Sum of code lengths for accepted symbols, including EOB.
    output logic [31:0]                           symbols_produced,    // Number of accepted decoded symbols, including EOB.
    output logic [63:0]                           cycle_count,         // Clock cycles spent with busy asserted.
    output logic [31:0]                           input_stall_cycles,  // Cycles byte_ready was high while byte_valid was low.
    output logic [31:0]                           output_stall_cycles  // Cycles symbol_valid was high while symbol_ready was low.
);

    localparam int TABLE_WIDTH    = $clog2(NUM_TABLES);       // Bits required to encode a table ID; default is three.
    localparam int SELECTOR_WIDTH = $clog2(MAX_SELECTORS);    // Bits required to address selector RAM; default is twelve.
    localparam int COUNT_WIDTH    = $clog2(MAX_SELECTORS + 1); // Bits required to represent counts through MAX_SELECTORS.

    localparam logic [7:0] ERR_NONE            = 8'h00; // No error has occurred.
    localparam logic [7:0] ERR_BAD_CONFIG      = 8'h02; // Missing, simultaneous, noncontiguous, or out-of-range configuration.
    localparam logic [7:0] ERR_TRUNCATED       = 8'h04; // Decode cannot continue after final byte, including final no-match.
    localparam logic [7:0] ERR_NO_SYMBOL       = 8'h05; // Full lookup window matched no configured entry.
    localparam logic [7:0] ERR_SELECTOR        = 8'h06; // Selector is exhausted or names an invalid table.
    localparam logic [7:0] ERR_OUTPUT_OVERFLOW = 8'h07; // Capacity was reached before an accepted EOB.

    logic [TABLE_WIDTH-1:0] selector_mem [0:MAX_SELECTORS-1]; // Table ID for every 50-symbol schedule group.
    logic [COUNT_WIDTH-1:0] selector_loaded_count_q; // Persistent size of the contiguous programmed selector prefix.
    logic [COUNT_WIDTH-1:0] selector_index_q;        // Registered selector entry currently controlling decode.
    logic [COUNT_WIDTH-1:0] next_selector_index;     // Combinational selector_index_q + 1 at a group boundary.
    logic [5:0]             symbols_in_group_q;      // Accepted non-EOB symbols in the current group, from 0 to 49.
    logic [COUNT_WIDTH-1:0] selector_count_q;        // Job-local selector count captured on start.
    logic [SYMBOL_WIDTH-1:0] eob_symbol_q;           // Job-local EOB value captured on start.
    logic [31:0]             symbol_capacity_q;      // Job-local maximum output count captured on start.
    logic                    config_error_pending_q; // Sticky record of an invalid idle-time configuration write.

    // Register the active table so the selector-memory read is not in the
    // normal selector -> CAM compare -> priority -> result timing path.
    // The next selector is captured only at start or a 50-symbol boundary.
    logic [TABLE_WIDTH-1:0] active_table_q;       // Registered bank ID kept stable across lookup and backpressure.
    logic                   active_table_valid_q; // Registered proof that active_table_q is valid for this job.
    logic                   selector_current_valid; // Combined bounds/range validity of current selector state.
    logic                   selector_write_good; // Legal idle-time selector write or contiguous append.
    logic                   selector_write_bad;  // Attempted idle-time selector write that violates those rules.

    logic                   matcher_lookup_valid;  // Request issued when job, selector, window, and capacity are ready.
    logic                   matcher_lookup_ready;  // Selected matcher can accept a new lookup into its result slot.
    logic                   matcher_result_valid;  // Selected matcher has one registered result pending.
    logic                   matcher_result_ready;  // Top accepts or internally drains that pending result.
    logic                   matcher_found;         // Pending result corresponds to a configured matching entry.
    logic [SYMBOL_WIDTH-1:0] matcher_symbol;        // Decoded symbol returned by the selected matcher.
    logic [4:0]              matcher_len;           // Code length returned by matcher and fed back to reservoir.
    logic                    dict_cfg_error;        // Six-bank wrapper detected an invalid dictionary write.

    logic                   reservoir_clear;         // One-cycle start action that resets stream position and alignment.
    logic                   reservoir_peek_valid;    // Reservoir has a full or final partial lookup window.
    logic [KEY_WIDTH-1:0]   reservoir_peek_bits;     // Current MSB-first lookup window sent to the matcher.
    logic [5:0]             reservoir_valid_bits;    // Count of real bits, excluding final zero padding.
    logic                   reservoir_last_seen;     // Sticky indication that the final byte was accepted.
    logic                   reservoir_consume_valid; // Accepted output requests removal of matcher_len bits.
    logic                   reservoir_consume_ready; // Reservoir confirms matcher_len real bits are available.
    logic                   output_fire;             // Atomic symbol-output and bit-consumption handshake event.
    logic                   result_length_available; // Rejects a match whose length reaches into padded bits.

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

// ============================================================================
// END ORIGINAL MODULE SOURCE: huffman_find_simple_top.sv
// ============================================================================
