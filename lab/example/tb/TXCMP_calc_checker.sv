module TXCMP_calc_checker (
  input clk, rst_n, valid_out, input [15:0] out_val,
  input [7:0] gain, shift, offset, output reg error_flag
);
  int cycle_cnt;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin error_flag <= 0; cycle_cnt <= 0; end
    else if (valid_out) begin
      automatic bit [23:0] golden = ((cycle_cnt==0?16'd100:cycle_cnt==1?16'd200:
        cycle_cnt==2?16'd500:cycle_cnt==3?16'd1000:cycle_cnt==4?16'd2000:
        cycle_cnt==5?16'd5000:cycle_cnt==6?16'd10000:cycle_cnt==7?16'd20000:
        cycle_cnt==8?16'd30000:16'd50000)*gain+offset+(shift>0?(1<<(shift-1)):0))>>shift;
      if (out_val !== golden[15:0]) begin
        $display("UVM_ERROR @ %0t: TXCMP mismatch cycle=%0d exp=0x%04x got=0x%04x", $time, cycle_cnt, golden[15:0], out_val);
        error_flag <= 1;
      end
      cycle_cnt <= cycle_cnt + 1;
    end
endmodule
