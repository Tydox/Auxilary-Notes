// 32-bit MSB-first byte-to-bit reservoir for the simplified pyflate design.
// Valid bits are always left aligned; peek_bits[15] is the next bit decoded.

`timescale 1ns / 1ps

module huffman_bit_reservoir #(
    parameter int BUFFER_WIDTH = 32,
    parameter int KEY_WIDTH    = 16
)(
    input  logic                         clk,
    // Assert asynchronously; deassert synchronously in the system wrapper.
    input  logic                         rst_n,
    input  logic                         active,
    input  logic                         clear,
    input  logic [2:0]                   start_bit,

    input  logic                         byte_valid,
    output logic                         byte_ready,
    input  logic [7:0]                   byte_data,
    input  logic                         byte_last,

    input  logic                         consume_valid,
    output logic                         consume_ready,
    input  logic [4:0]                   consume_len,

    output logic                         peek_valid,
    output logic [KEY_WIDTH-1:0]         peek_bits,
    output logic [$clog2(BUFFER_WIDTH+1)-1:0] valid_bits,
    output logic                         input_last_seen
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
