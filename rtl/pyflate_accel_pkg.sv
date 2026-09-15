package pyflate_accel_pkg;

  localparam logic [31:0] PYFLATE_ID      = 32'h5059_464c; // "PYFL"
  localparam logic [31:0] PYFLATE_VERSION = 32'h0001_0000; // 1.0

  localparam logic [11:0] REG_ID              = 12'h000;
  localparam logic [11:0] REG_VERSION         = 12'h004;
  localparam logic [11:0] REG_CAPABILITIES    = 12'h008;
  localparam logic [11:0] REG_CONTROL         = 12'h00c;
  localparam logic [11:0] REG_STATUS          = 12'h010;
  localparam logic [11:0] REG_IRQ_ENABLE      = 12'h014;
  localparam logic [11:0] REG_IRQ_STATUS      = 12'h018;
  localparam logic [11:0] REG_ERROR_CODE      = 12'h01c;
  localparam logic [11:0] REG_SRC_ADDR_LO     = 12'h020;
  localparam logic [11:0] REG_SRC_ADDR_HI     = 12'h024;
  localparam logic [11:0] REG_SRC_LENGTH      = 12'h028;
  localparam logic [11:0] REG_DST_ADDR_LO     = 12'h02c;
  localparam logic [11:0] REG_DST_ADDR_HI     = 12'h030;
  localparam logic [11:0] REG_DST_CAPACITY    = 12'h034;
  localparam logic [11:0] REG_WORK_ADDR_LO    = 12'h038;
  localparam logic [11:0] REG_WORK_ADDR_HI    = 12'h03c;
  localparam logic [11:0] REG_WORK_SIZE       = 12'h040;
  localparam logic [11:0] REG_OPTIONS         = 12'h044;
  localparam logic [11:0] REG_OUTPUT_LENGTH   = 12'h048;
  localparam logic [11:0] REG_INPUT_CONSUMED  = 12'h04c;
  localparam logic [11:0] REG_BLOCK_COUNT     = 12'h050;
  localparam logic [11:0] REG_CYCLE_COUNT_LO  = 12'h054;
  localparam logic [11:0] REG_CYCLE_COUNT_HI  = 12'h058;
  localparam logic [11:0] REG_HUFFMAN_SYMBOLS = 12'h05c;
  localparam logic [11:0] REG_DATA_MTF_OPS     = 12'h060;
  localparam logic [11:0] REG_BWT_BYTES        = 12'h064;
  localparam logic [11:0] REG_DMA_READ_STALLS  = 12'h068;
  localparam logic [11:0] REG_DMA_WRITE_STALLS = 12'h06c;
  localparam logic [11:0] REG_CORE_STALLS      = 12'h070;
  localparam logic [11:0] REG_MAX_BLOCK_BYTES  = 12'h074;

  localparam int unsigned CONTROL_START_BIT      = 0;
  localparam int unsigned CONTROL_ABORT_BIT      = 1;
  localparam int unsigned CONTROL_SOFT_RESET_BIT = 2;

  localparam int unsigned STATUS_BUSY_BIT        = 0;
  localparam int unsigned STATUS_DONE_BIT        = 1;
  localparam int unsigned STATUS_ERROR_BIT       = 2;
  localparam int unsigned STATUS_ABORTED_BIT     = 3;
  localparam int unsigned STATUS_IRQ_PENDING_BIT = 4;

  localparam int unsigned IRQ_DONE_BIT  = 0;
  localparam int unsigned IRQ_ERROR_BIT = 1;

  localparam int unsigned OPTION_BLOCK_CRC_BIT       = 0;
  localparam int unsigned OPTION_STREAM_CRC_BIT      = 1;
  localparam int unsigned OPTION_BENCHMARK_COMPAT_BIT = 2;

  localparam int unsigned CAP_BZH1_TO_9_BIT       = 0;
  localparam int unsigned CAP_BLOCK_CRC_BIT       = 1;
  localparam int unsigned CAP_STREAM_CRC_BIT      = 2;
  localparam int unsigned CAP_EXTERNAL_WORK_BIT   = 3;
  localparam int unsigned CAP_ONCHIP_WORK_BIT     = 4;
  localparam int unsigned CAP_PERF_COUNTERS_BIT   = 5;

  typedef enum logic [7:0] {
    ERR_NONE           = 8'h00,
    ERR_BUSY           = 8'h01,
    ERR_BAD_CONFIG     = 8'h02,
    ERR_BAD_MAGIC      = 8'h03,
    ERR_TRUNCATED      = 8'h04,
    ERR_RANDOMIZED     = 8'h05,
    ERR_SELECTOR       = 8'h06,
    ERR_HUFFMAN_TABLE  = 8'h07,
    ERR_HUFFMAN_SYMBOL = 8'h08,
    ERR_BLOCK_OVERFLOW = 8'h09,
    ERR_BWT_POINTER    = 8'h0a,
    ERR_DST_OVERFLOW   = 8'h0b,
    ERR_BLOCK_CRC      = 8'h0c,
    ERR_STREAM_CRC     = 8'h0d,
    ERR_DMA_READ       = 8'h0e,
    ERR_DMA_WRITE      = 8'h0f,
    ERR_ABORTED        = 8'h10,
    ERR_INTERNAL       = 8'hff
  } pyflate_error_e;

endpackage

