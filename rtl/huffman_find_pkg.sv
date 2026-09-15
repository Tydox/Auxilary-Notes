package huffman_find_pkg;

  localparam logic [31:0] HUFFMAN_FIND_ID      = 32'h4846_494e; // "HFIN"
  localparam logic [31:0] HUFFMAN_FIND_VERSION = 32'h0001_0000; // 1.0

  localparam logic [11:0] REG_ID                 = 12'h000;
  localparam logic [11:0] REG_VERSION            = 12'h004;
  localparam logic [11:0] REG_CAPABILITIES       = 12'h008;
  localparam logic [11:0] REG_CONTROL            = 12'h00c;
  localparam logic [11:0] REG_STATUS             = 12'h010;
  localparam logic [11:0] REG_ERROR_CODE         = 12'h014;
  localparam logic [11:0] REG_SRC_ADDR_LO        = 12'h020;
  localparam logic [11:0] REG_SRC_ADDR_HI        = 12'h024;
  localparam logic [11:0] REG_SRC_LENGTH         = 12'h028;
  localparam logic [11:0] REG_START_BIT           = 12'h02c;
  localparam logic [11:0] REG_TABLE_ADDR_LO       = 12'h030;
  localparam logic [11:0] REG_TABLE_ADDR_HI       = 12'h034;
  localparam logic [11:0] REG_SELECTOR_ADDR_LO    = 12'h038;
  localparam logic [11:0] REG_SELECTOR_ADDR_HI    = 12'h03c;
  localparam logic [11:0] REG_SELECTOR_COUNT      = 12'h040;
  localparam logic [11:0] REG_TABLE_COUNT         = 12'h044;
  localparam logic [11:0] REG_EOB_SYMBOL          = 12'h048;
  localparam logic [11:0] REG_DST_ADDR_LO         = 12'h050;
  localparam logic [11:0] REG_DST_ADDR_HI         = 12'h054;
  localparam logic [11:0] REG_DST_SYMBOL_CAPACITY = 12'h058;
  localparam logic [11:0] REG_BITS_CONSUMED       = 12'h060;
  localparam logic [11:0] REG_SYMBOLS_PRODUCED    = 12'h064;
  localparam logic [11:0] REG_CYCLE_COUNT_LO      = 12'h068;
  localparam logic [11:0] REG_CYCLE_COUNT_HI      = 12'h06c;
  localparam logic [11:0] REG_INPUT_STALLS        = 12'h070;
  localparam logic [11:0] REG_OUTPUT_STALLS       = 12'h074;

  typedef enum logic [7:0] {
    HFIN_ERR_NONE            = 8'h00,
    HFIN_ERR_BUSY            = 8'h01,
    HFIN_ERR_BAD_CONFIG      = 8'h02,
    HFIN_ERR_BAD_KEEP        = 8'h03,
    HFIN_ERR_TRUNCATED       = 8'h04,
    HFIN_ERR_NO_SYMBOL       = 8'h05,
    HFIN_ERR_SELECTOR        = 8'h06,
    HFIN_ERR_OUTPUT_OVERFLOW = 8'h07,
    HFIN_ERR_DMA_READ        = 8'h08,
    HFIN_ERR_DMA_WRITE       = 8'h09,
    HFIN_ERR_ABORTED         = 8'h0a,
    HFIN_ERR_INTERNAL        = 8'hff
  } huffman_find_error_e;

endpackage
