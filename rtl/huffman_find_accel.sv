module huffman_find_accel #(
  parameter int unsigned INPUT_W       = 64,
  parameter int unsigned MAX_TABLES    = 6,
  parameter int unsigned MAX_SYMBOLS   = 258,
  parameter int unsigned MAX_CODE_BITS = 20,
  parameter int unsigned MAX_SELECTORS = 32768
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  // Configuration writes are accepted only while idle. first_code is the
  // right-aligned canonical code for cfg_length; first_index addresses perm.
  input  logic                         cfg_range_valid_i,
  output logic                         cfg_range_ready_o,
  input  logic [$clog2(MAX_TABLES)-1:0] cfg_range_table_i,
  input  logic [4:0]                   cfg_range_length_i,
  input  logic [MAX_CODE_BITS-1:0]     cfg_range_first_code_i,
  input  logic [8:0]                   cfg_range_first_index_i,
  input  logic [8:0]                   cfg_range_count_i,

  input  logic                         cfg_perm_valid_i,
  output logic                         cfg_perm_ready_o,
  input  logic [$clog2(MAX_TABLES)-1:0] cfg_perm_table_i,
  input  logic [8:0]                   cfg_perm_index_i,
  input  logic [8:0]                   cfg_perm_symbol_i,

  input  logic                         cfg_selector_valid_i,
  output logic                         cfg_selector_ready_o,
  input  logic [$clog2(MAX_SELECTORS)-1:0] cfg_selector_index_i,
  input  logic [$clog2(MAX_TABLES)-1:0] cfg_selector_table_i,

  // One start describes a complete contiguous Huffman payload. Bit offset zero
  // means the MSB of byte zero. symbols_max_i includes the EOB symbol.
  input  logic                         start_i,
  input  logic [2:0]                   start_bit_i,
  input  logic [2:0]                   table_count_i,
  input  logic [15:0]                  selector_count_i,
  input  logic [8:0]                   eob_symbol_i,
  input  logic [31:0]                  symbols_max_i,

  // Byte zero is s_data_i[7:0], matching little-endian AXI memory lanes.
  // Within each byte, compressed bits are consumed MSB first.
  input  logic                         s_valid_i,
  output logic                         s_ready_o,
  input  logic [INPUT_W-1:0]           s_data_i,
  input  logic [INPUT_W/8-1:0]         s_keep_i,
  input  logic                         s_last_i,

  // Output is held stable under backpressure. The EOB symbol is emitted.
  output logic                         m_valid_o,
  input  logic                         m_ready_i,
  output logic [8:0]                   m_symbol_o,
  output logic [4:0]                   m_code_length_o,
  output logic [2:0]                   m_table_o,
  output logic                         m_eob_o,

  output logic                         busy_o,
  output logic                         done_o,
  output logic                         error_o,
  output logic [7:0]                   error_code_o,
  output logic [31:0]                  bits_consumed_o,
  output logic [31:0]                  symbols_produced_o
);

  localparam int unsigned INPUT_BYTES = INPUT_W / 8;
  localparam int unsigned BUFFER_W    = 2 * INPUT_W;
  localparam int unsigned TABLE_W     = $clog2(MAX_TABLES);
  localparam int unsigned SELECTOR_W  = $clog2(MAX_SELECTORS);

  localparam logic [7:0] ERR_NONE            = 8'h00;
  localparam logic [7:0] ERR_BAD_CONFIG      = 8'h02;
  localparam logic [7:0] ERR_BAD_KEEP        = 8'h03;
  localparam logic [7:0] ERR_TRUNCATED       = 8'h04;
  localparam logic [7:0] ERR_NO_SYMBOL       = 8'h05;
  localparam logic [7:0] ERR_SELECTOR        = 8'h06;
  localparam logic [7:0] ERR_OUTPUT_OVERFLOW = 8'h07;

  logic [MAX_CODE_BITS-1:0]
      first_code_mem [0:MAX_TABLES-1][1:MAX_CODE_BITS];
  logic [8:0] first_index_mem [0:MAX_TABLES-1][1:MAX_CODE_BITS];
  logic [8:0] count_mem       [0:MAX_TABLES-1][1:MAX_CODE_BITS];
  logic [8:0] perm_mem        [0:MAX_TABLES-1][0:MAX_SYMBOLS-1];
  logic [TABLE_W-1:0] selector_mem [0:MAX_SELECTORS-1];

  logic [BUFFER_W-1:0] bit_buffer_q, bit_buffer_n;
  logic [$clog2(BUFFER_W+1)-1:0] bit_count_q, bit_count_n;
  logic first_beat_q, input_last_q;
  logic [15:0] selector_index_q;
  logic [5:0] symbols_in_group_q;

  logic [TABLE_W-1:0] active_table;
  logic match_found;
  logic [4:0] match_length;
  logic [8:0] match_index;
  logic [8:0] match_symbol;
  logic [MAX_CODE_BITS-1:0] peek_bits;
  logic take_symbol, take_input;
  logic keep_is_contiguous;
  logic [$clog2(INPUT_BYTES+1)-1:0] input_byte_count;
  logic [BUFFER_W-1:0] incoming_bits;
  logic [$clog2(BUFFER_W+1)-1:0] incoming_bit_count;
  logic decode_failure;

  integer length_i;
  integer byte_i;

  assign cfg_range_ready_o    = !busy_o;
  assign cfg_perm_ready_o     = !busy_o;
  assign cfg_selector_ready_o = !busy_o;

  assign active_table = selector_mem[selector_index_q[SELECTOR_W-1:0]];
  assign peek_bits    = bit_buffer_q[BUFFER_W-1 -: MAX_CODE_BITS];

  // AXI-style keep must be nonzero and contiguous from lane zero: 01, 03,
  // 07, ... ff. A full beat is therefore legal despite eight-bit wraparound.
  always_comb begin
    keep_is_contiguous = (s_keep_i != '0) &&
                         ((s_keep_i & (s_keep_i + {{(INPUT_BYTES-1){1'b0}},1'b1})) == '0);
    input_byte_count = '0;
    incoming_bits = '0;
    for (byte_i = 0; byte_i < INPUT_BYTES; byte_i = byte_i + 1) begin
      if (s_keep_i[byte_i]) begin
        input_byte_count = input_byte_count + 1'b1;
        incoming_bits[BUFFER_W-1-(8*byte_i) -: 8] = s_data_i[(8*byte_i) +: 8];
      end
    end
    incoming_bit_count = input_byte_count * 8;
    if (first_beat_q) begin
      incoming_bits = incoming_bits << start_bit_i;
      if (incoming_bit_count >= start_bit_i)
        incoming_bit_count = incoming_bit_count - start_bit_i;
      else
        incoming_bit_count = '0;
    end
  end

  // Parallel canonical decoder. For each legal length L, prefix is the next
  // L bits interpreted as an unsigned MSB-first integer. Canonical ranges do
  // not overlap; priority selects the shortest matching length.
  always_comb begin
    match_found  = 1'b0;
    match_length = '0;
    match_index  = '0;
    match_symbol = '0;
    for (length_i = 1; length_i <= MAX_CODE_BITS; length_i = length_i + 1) begin
      if (!match_found && (length_i <= bit_count_q) &&
          (count_mem[active_table][length_i] != 0) &&
          ({1'b0, (peek_bits >> (MAX_CODE_BITS-length_i))} >=
             {1'b0, first_code_mem[active_table][length_i]}) &&
          ({1'b0, (peek_bits >> (MAX_CODE_BITS-length_i))} <
             ({1'b0, first_code_mem[active_table][length_i]} +
              {{(MAX_CODE_BITS+1-9){1'b0}},
               count_mem[active_table][length_i]}))) begin
        match_found  = 1'b1;
        match_length = length_i[4:0];
        match_index  = first_index_mem[active_table][length_i] +
                       (peek_bits >> (MAX_CODE_BITS-length_i)) -
                       first_code_mem[active_table][length_i];
      end
    end
    if (match_found && (match_index < MAX_SYMBOLS))
      match_symbol = perm_mem[active_table][match_index];
  end

  assign m_valid_o       = busy_o && match_found &&
                           (active_table < table_count_i) &&
                           (symbols_produced_o < symbols_max_i);
  assign m_symbol_o      = match_symbol;
  assign m_code_length_o = match_length;
  assign m_table_o       = {{(3-TABLE_W){1'b0}}, active_table};
  assign m_eob_o         = (match_symbol == eob_symbol_i);
  assign take_symbol     = m_valid_o && m_ready_i;

  // Reserving one full input beat avoids overflow. Input may be accepted in
  // the same cycle as a symbol, and the next-state logic consumes first.
  assign s_ready_o = busy_o && !input_last_q &&
                     (bit_count_q <= (BUFFER_W-INPUT_W)) &&
                     !(m_valid_o && !m_ready_i);
  assign take_input = s_valid_i && s_ready_o;

  assign decode_failure = busy_o && !match_found &&
                          ((bit_count_q >= MAX_CODE_BITS) || input_last_q);

  always_comb begin
    bit_buffer_n = bit_buffer_q;
    bit_count_n  = bit_count_q;

    if (take_symbol) begin
      bit_buffer_n = bit_buffer_n << match_length;
      bit_count_n  = bit_count_n - match_length;
    end

    if (take_input && keep_is_contiguous) begin
      bit_buffer_n = bit_buffer_n |
                     (incoming_bits >> bit_count_n);
      bit_count_n  = bit_count_n + incoming_bit_count;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_o                <= 1'b0;
      done_o                <= 1'b0;
      error_o               <= 1'b0;
      error_code_o          <= ERR_NONE;
      bits_consumed_o       <= '0;
      symbols_produced_o    <= '0;
      bit_buffer_q          <= '0;
      bit_count_q           <= '0;
      first_beat_q          <= 1'b1;
      input_last_q          <= 1'b0;
      selector_index_q      <= '0;
      symbols_in_group_q    <= '0;
    end else begin
      done_o <= 1'b0;

      if (cfg_range_valid_i && cfg_range_ready_o &&
          (cfg_range_table_i < MAX_TABLES) &&
          (cfg_range_length_i >= 1) &&
          (cfg_range_length_i <= MAX_CODE_BITS)) begin
        first_code_mem[cfg_range_table_i][cfg_range_length_i]
          <= cfg_range_first_code_i;
        first_index_mem[cfg_range_table_i][cfg_range_length_i]
          <= cfg_range_first_index_i;
        count_mem[cfg_range_table_i][cfg_range_length_i]
          <= cfg_range_count_i;
      end

      if (cfg_perm_valid_i && cfg_perm_ready_o &&
          (cfg_perm_table_i < MAX_TABLES) &&
          (cfg_perm_index_i < MAX_SYMBOLS))
        perm_mem[cfg_perm_table_i][cfg_perm_index_i] <= cfg_perm_symbol_i;

      if (cfg_selector_valid_i && cfg_selector_ready_o &&
          (cfg_selector_index_i < MAX_SELECTORS))
        selector_mem[cfg_selector_index_i] <= cfg_selector_table_i;

      if (!busy_o) begin
        if (start_i) begin
          error_o            <= 1'b0;
          error_code_o       <= ERR_NONE;
          bits_consumed_o    <= '0;
          symbols_produced_o <= '0;
          bit_buffer_q       <= '0;
          bit_count_q        <= '0;
          first_beat_q       <= 1'b1;
          input_last_q       <= 1'b0;
          selector_index_q   <= '0;
          symbols_in_group_q <= '0;
          if ((table_count_i < 2) || (table_count_i > MAX_TABLES) ||
              (selector_count_i == 0) ||
              (selector_count_i > MAX_SELECTORS) ||
              (symbols_max_i == 0) ||
              (eob_symbol_i >= MAX_SYMBOLS)) begin
            error_o      <= 1'b1;
            error_code_o <= ERR_BAD_CONFIG;
            done_o       <= 1'b1;
          end else begin
            busy_o <= 1'b1;
          end
        end
      end else if (take_input && !keep_is_contiguous) begin
        busy_o       <= 1'b0;
        error_o      <= 1'b1;
        error_code_o <= ERR_BAD_KEEP;
        done_o       <= 1'b1;
      end else if (active_table >= table_count_i) begin
        busy_o       <= 1'b0;
        error_o      <= 1'b1;
        error_code_o <= ERR_SELECTOR;
        done_o       <= 1'b1;
      end else if (symbols_produced_o >= symbols_max_i) begin
        busy_o       <= 1'b0;
        error_o      <= 1'b1;
        error_code_o <= ERR_OUTPUT_OVERFLOW;
        done_o       <= 1'b1;
      end else if (decode_failure) begin
        busy_o       <= 1'b0;
        error_o      <= 1'b1;
        error_code_o <= input_last_q ? ERR_TRUNCATED : ERR_NO_SYMBOL;
        done_o       <= 1'b1;
      end else begin
        bit_buffer_q <= bit_buffer_n;
        bit_count_q  <= bit_count_n;

        if (take_input) begin
          first_beat_q <= 1'b0;
          if (s_last_i)
            input_last_q <= 1'b1;
        end

        if (take_symbol) begin
          bits_consumed_o    <= bits_consumed_o + match_length;
          symbols_produced_o <= symbols_produced_o + 1'b1;
          if (m_eob_o) begin
            busy_o  <= 1'b0;
            done_o  <= 1'b1;
          end else if (symbols_in_group_q == 6'd49) begin
            symbols_in_group_q <= '0;
            if ((selector_index_q + 1'b1) >= selector_count_i) begin
              busy_o       <= 1'b0;
              error_o      <= 1'b1;
              error_code_o <= ERR_SELECTOR;
              done_o       <= 1'b1;
            end else begin
              selector_index_q <= selector_index_q + 1'b1;
            end
          end else begin
            symbols_in_group_q <= symbols_in_group_q + 1'b1;
          end
        end
      end
    end
  end

endmodule
