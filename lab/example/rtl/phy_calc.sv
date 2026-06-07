// CORRECT: round-to-nearest
module phy_calc (
  input         clk, rst_n, valid_in,
  input  [15:0] in_val,
  input  [7:0]  gain, shift, offset,
  output reg [15:0] out_val,
  output reg    valid_out
);
  wire [23:0] mult = in_val * gain;
  wire [23:0] added = mult + offset;
  wire [23:0] round_bit = (shift > 0) ? (1 << (shift - 1)) : 0;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin out_val <= 0; valid_out <= 0; end
    else if (valid_in) begin out_val <= (added + round_bit) >> shift; valid_out <= 1; end
    else valid_out <= 0;
endmodule
