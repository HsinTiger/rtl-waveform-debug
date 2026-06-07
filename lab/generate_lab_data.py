#!/usr/bin/env python3
"""
generate_lab_data.py — Generate all files for the self-contained lab example.

Creates lab/example/ with pre-generated VCDs, RTL, golden hex, and sim files.

Run: python3 lab/generate_lab_data.py
"""

import os, json

OUT = os.path.join(os.path.dirname(__file__) or ".", "example")
gain, shift, offset = 5, 3, 0
T = 10  # clock period
test_vals = [100, 200, 500, 1000, 2000, 5000, 10000, 20000, 30000, 50000]

def calc(v, do_round=True):
    mult = v * gain + offset
    if do_round and shift > 0:
        return (mult + (1 << (shift - 1))) >> shift
    return mult >> shift

corr_outs  = [min(max(calc(v, True),  0), 0xFFFF) for v in test_vals]
buggy_outs = [min(max(calc(v, False), 0), 0xFFFF) for v in test_vals]
mismatches = sum(1 for c, b in zip(corr_outs, buggy_outs) if c != b)

# ── VCD generator ──────────────────────────────────────────────
def vec(val_bin, id_char):
    """Vector value line: 'b<binary> <id>'"""
    return f"b{val_bin} {id_char}"

def scal(val, id_char):
    """Scalar value line: '<val><id>'"""
    return f"{val}{id_char}"

def gen_vcd(outs):
    """2-cycle pipeline: every posedge has valid out_val (except first).
    Clock toggles every 5ns. Posedges at 5, 15, 25, ..."""
    def line(t, *pairs):
        parts = []
        for v, id_ in pairs:
            parts.append(f"{v}{id_}" if v in '01xz' else f"b{v} {id_}")
        return f"#{t} " + ' '.join(parts)

    header = f"""$timescale 1ns $end
$scope module tb $end
$scope module dut $end
$var wire 1 ! clk $end
$var wire 1 " rst_n $end
$var wire 1 # valid_in $end
$var wire 1 $ valid_out $end
$var wire 16 % in_val $end
$var wire 16 & out_val $end
$var wire 8 ' gain $end
$var wire 8 ( shift $end
$var wire 8 ) offset $end
$upscope $end
$scope module TXCMP $end
$var wire 1 * error_flag $end
$var wire 16 + exp_val $end
$var wire 16 , act_val $end
$upscope $end
$upscope $end
$enddefinitions $end
$dumpvars
{line(0, ('0','!'), ('1','"'), ('0','#'), ('0','$'), ('x'*16,'%'), ('x'*16,'&'), (f'{gain:08b}',"'"), (f'{shift:08b}','('), (f'{offset:08b}',')'))}
{line(0, ('0','*'), ('0'*16,'+'), ('0'*16,','))}
$end"""
    lines = header.split('\n')

    # t=2: rst_n deassert
    lines.append(line(2, ('1','"')))

    # t=5: first posedge — apply input[0], out_val=x (not ready yet)
    v0 = test_vals[0]
    lines.append(line(5, ('1','!'), ('1','#'), (f'{v0:016b}','%'),
                      (f'{gain:08b}',"'"), (f'{shift:08b}','('), (f'{offset:08b}',')')))
    lines.append(line(10, ('0','!'), ('0','#')))

    # t=15, 25, 35, ...: posedge N — out = result[N-1], apply input[N]
    for i in range(len(test_vals)):
        t = 15 + 10 * i
        outv = outs[i]
        expv = corr_outs[i]
        items = [('1','!')]  # posedge
        items += [('1','$'), (f'{outv:016b}','&')]  # valid_out, out_val
        if outv != expv:
            items.append(('1','*'))
        items += [(f'{expv:016b}','+'), (f'{outv:016b}',',')]
        # Apply next input if available
        if i + 1 < len(test_vals):
            items += [('1','#'), (f'{test_vals[i+1]:016b}','%'),
                      (f'{gain:08b}',"'"), (f'{shift:08b}','('), (f'{offset:08b}',')')]
        else:
            items += [('0','#')]
        lines.append(line(t, *items))
        lines.append(line(t+5, ('0','!'), ('0','#'), ('0','$')))

    return lines


# ── Write files ────────────────────────────────────────────────
def main():
    dirs = [f"{OUT}/rtl", f"{OUT}/tb", f"{OUT}/golden", f"{OUT}/sim", f"{OUT}/config"]
    for d in dirs:
        os.makedirs(d, exist_ok=True)

    # RTL
    with open(f"{OUT}/rtl/phy_calc.sv", 'w') as f:
        f.write(r"""// CORRECT: round-to-nearest
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
""")

    with open(f"{OUT}/rtl/phy_calc_buggy.sv", 'w') as f:
        f.write(r"""// BUGGY: uses truncation (no round-to-nearest)
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
""")

    # Testbench + checker
    with open(f"{OUT}/tb/testbench.sv", 'w') as f:
        f.write("""\
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
""")

    with open(f"{OUT}/tb/TXCMP_calc_checker.sv", 'w') as f:
        f.write("""\
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
""")

    # sim_setting
    for name, cfg in [("sim_setting.json", {
            "phy_calc": {"parameters": {"gain": gain, "shift_bits": shift, "offset": offset,
                          "round_mode": "round_to_nearest", "data_width": 16, "latency_cycles": 2},
                         "phyUD": {"dump_nodes": ["phy_calc.out_val"], "dump_format": "hex", "dump_scope": "tb.dut"}}}),
                      ("sim_setting_wrong.json", {
            "phy_calc": {"parameters": {"gain": 16, "shift_bits": 3, "offset": 0,
                          "round_mode": "truncation", "data_width": 16, "latency_cycles": 2},
                         "phyUD": {"dump_nodes": ["phy_calc.out_val"], "dump_format": "hex", "dump_scope": "tb"}}})]:
        with open(f"{OUT}/sim/{name}", 'w') as f:
            json.dump(cfg, f, indent=2)

    # Golden hex
    with open(f"{OUT}/golden/phy_calc.hex", 'w') as f:
        for i, v in enumerate(test_vals):
            val = min(max(calc(v, True), 0), 0xFFFF)
            f.write(f"{i}\t{val:04X}\n")

    # VCDs
    for name, outs in [("dump_correct.vcd", corr_outs), ("dump_buggy.vcd", buggy_outs)]:
        lines = gen_vcd(outs)
        with open(f"{OUT}/sim/{name}", 'w') as f:
            f.write('\n'.join(lines) + '\n')

    # VCS log
    with open(f"{OUT}/sim/vcs.log", 'w') as f:
        f.write("*** VCS MX 2023.12 ***\n")
        f.write("Simulation started: 2026-06-07\n\n")
        f.write("sim_setting loaded: /proj/lab/sim/sim_setting.json\n")
        f.write("phyUD platform version: 4.21\n")
        f.write("Intermediate nodes to dump: phy_calc.out_val\n\n")
        f.write("UVM_INFO @ 0: Reset sequence started\n")
        f.write("UVM_INFO @ 10: Reset done\n\n")
        for i, v in enumerate(test_vals):
            g, b = calc(v, True), calc(v, False)
            if g != b:
                f.write(f"UVM_ERROR @ {30+i*30} ns: TXCMP mismatch cycle={i} exp=0x{g:04X} got=0x{b:04X}\n")
        f.write(f"\nUVM_ERROR Count: {mismatches}\nUVM_FATAL: 0\n*** Simulation finished ***\n")

    print(f"✅ Generated lab/example/ — {len(test_vals)} test cases, {mismatches} mismatches")
    for name in sorted(os.listdir(f"{OUT}/rtl")):
        print(f"   rtl/{name}")
    for name in sorted(os.listdir(f"{OUT}/tb")):
        print(f"   tb/{name}")
    for name in sorted(os.listdir(f"{OUT}/sim")):
        print(f"   sim/{name}")
    for name in sorted(os.listdir(f"{OUT}/golden")):
        print(f"   golden/{name}")

if __name__ == "__main__":
    main()
