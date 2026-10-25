// Testbench of the MMCME4_ADV simulation model (Verilator --binary --timing).
// 100 MHz in, VCO 1000 MHz; CLKOUT0 /2.5, CLKOUT1 /8 with 90 degrees, CLKOUT2 /10.
module tb;
  timeunit 1ns;
  timeprecision 1ps;

  logic clkin, rst, fb;
  logic c0, c0b, c1, c2, locked;
  logic cfb;
  int errors;

  initial clkin = 1'b0;
  always #5 clkin = ~clkin;

  MMCME4_ADV #(
    .CLKIN1_PERIOD(10.0), .CLKFBOUT_MULT_F(10.0), .DIVCLK_DIVIDE(1),
    .CLKOUT0_DIVIDE_F(2.5), .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(90.0), .CLKOUT2_DIVIDE(10)
  ) m (
    .CLKIN1(clkin), .RST(rst), .CLKFBIN(cfb), .CLKFBOUT(cfb), .PWRDWN(1'b0),
    .CLKOUT0(c0), .CLKOUT0B(c0b), .CLKOUT1(c1), .CLKOUT2(c2), .LOCKED(locked)
  );

  real last0, last1, last2, first0, first1, lastfb, lastedge;
  int n0, n1, n2;

  task automatic check(input string what, input real got, input real want);
    if (got > want + 0.002 || got < want - 0.002) begin
      $display("FAIL %s: got %f want %f at %t", what, got, want, $realtime);
      errors++;
    end
  endtask

  always @(posedge c0) begin
    if (n0 == 0) first0 = $realtime; else check("CLKOUT0 period", $realtime - last0, 2.5);
    last0 = $realtime; lastedge = $realtime; n0++;
  end
  always @(posedge c1) begin
    if (n1 == 0) first1 = $realtime; else check("CLKOUT1 period", $realtime - last1, 8.0);
    last1 = $realtime; n1++;
  end
  always @(posedge c2) begin
    if (n2 > 0) check("CLKOUT2 period", $realtime - last2, 10.0);
    last2 = $realtime; n2++;
  end
  always @(posedge cfb) begin
    if (lastfb != 0.0) check("CLKFBOUT period", $realtime - lastfb, 10.0);
    lastfb = $realtime;
  end
  // the inverted output is the complement of CLKOUT0 whenever it runs
  always @(negedge c0) #0.01 if (c0b !== 1'b1) begin $display("FAIL CLKOUT0B"); errors++; end

  initial begin
    rst = 1'b1;
    n0 = 0; n1 = 0; n2 = 0; lastfb = 0.0; errors = 0;
    #20 rst = 1'b0;
    if (c0 !== 1'b0 || c1 !== 1'b0) begin $display("FAIL clocks run in reset"); errors++; end
    #150 if (locked !== 1'b0) begin $display("FAIL locked early"); errors++; end
    #10 if (locked !== 1'b1) begin $display("FAIL not locked after 16 cycles"); errors++; end
    #190;
    // first edges: CLKOUT0 at the first CLKIN1 edge after reset, CLKOUT1 90 degrees (2 ns) later
    check("phase", first1 - first0, 2.0);
    check("CLKOUT0 edges", real'(n0), 138.0);
    rst = 1'b1;
    #11 if (locked !== 1'b0) begin $display("FAIL locked in reset"); errors++; end
    #30;
    if ($realtime - last0 < 25.0) begin $display("FAIL clock still running in reset"); errors++; end
    if (errors == 0) $display("PASS");
    $finish;
  end
endmodule
