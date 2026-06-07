`timescale 1ns/1ps
module tb;
  reg clk, rst_n, valid_in; reg [15:0] in_val;
  reg [7:0] gain, shift, offset;
  wire [15:0] out_val; wire valid_out;
  phy_calc dut (.*);
  always #5 clk = ~clk;
  initial begin $dumpfile("dump.vcd"); $dumpvars(0, tb); end
  initial begin
    clk=0; rst_n=0; valid_in=0; in_val=0; gain=8'd5; shift=8'd3; offset=8'd0;
    @(posedge clk); rst_n=1; @(posedge clk);
    apply_input(16'd100); apply_input(16'd200); apply_input(16'd500);
    apply_input(16'd1000); apply_input(16'd2000); apply_input(16'd5000);
    apply_input(16'd10000); apply_input(16'd20000); apply_input(16'd30000);
    apply_input(16'd50000);
    #100; $display("*** TEST DONE ***"); $finish;
  end
  task apply_input(input [15:0] val);
    @(posedge clk); valid_in=1; in_val=val; @(posedge clk); valid_in=0;
    @(posedge clk);
    if (valid_out) begin
      int exp = ((val * gain) + offset + (shift>0?(1<<(shift-1)):0)) >> shift;
      if (dut.out_val !== exp[15:0])
        $display("UVM_ERROR @ %0t: mismatch in=0x%04x exp=0x%04x got=0x%04x", $time, val, exp[15:0], dut.out_val);
    end
    @(posedge clk);
  endtask
endmodule
