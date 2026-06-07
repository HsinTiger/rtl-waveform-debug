// BUGGY: uses truncation (no round-to-nearest)
module phy_calc (
  input         clk, rst_n, valid_in,
  input  [15:0] in_val,
  input  [7:0]  gain, shift, offset,
  output reg [15:0] out_val,
  output reg    valid_out
);
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin out_val <= 0; valid_out <= 0; end
    else if (valid_in) begin
      // BUG: missing round_bit term — truncation instead of rounding
      out_val <= ((in_val * gain) + offset) >> shift;
      valid_out <= 1;
    end
    else valid_out <= 0;
endmodule
