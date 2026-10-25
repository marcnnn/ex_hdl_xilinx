// Testbench of the BUFG_GT simulation model: division, duty cycle, CE and CLR.
module tb;
  timeunit 1ns;
  timeprecision 1ps;

  logic i, ce, clr;
  logic [2:0] div;
  logic o;
  int errors;

  initial i = 1'b0;
  always #5 i = ~i;

  BUFG_GT g (.I(i), .CE(ce), .CEMASK(1'b0), .CLR(clr), .CLRMASK(1'b0), .DIV(div), .O(o));

  int highs, rises;
  logic prev;
  always @(posedge o) rises++;
  always @(negedge i) begin
    if (o) highs++;
  end

  initial begin
    errors = 0;
    ce = 1'b1; clr = 1'b0; div = 3'd0;
    for (int d = 0; d < 8; d++) begin
      int n, cycles;
      n = d + 1;
      cycles = 840;
      div = 3'(d);
      clr = 1'b1; #1 clr = 1'b0;
      @(posedge i);
      highs = 0; rises = 0;
      repeat (cycles) @(posedge i);
      #1;
      // rising edges of O: one per n input cycles, high for ceil(n / 2) of them
      if (d == 0) begin
        if (rises < cycles - 1 || rises > cycles + 1) begin $display("FAIL div 1 rises %0d", rises); errors++; end
      end else begin
        if (rises < cycles / n - 1 || rises > cycles / n + 1) begin $display("FAIL div %0d rises %0d", n, rises); errors++; end
        if (highs < cycles / n * ((n + 1) / 2) - n || highs > cycles / n * ((n + 1) / 2) + n) begin
          $display("FAIL div %0d highs %0d", n, highs); errors++;
        end
      end
    end

    // CE low (changed while I is low) stops the output, CE high restarts it
    div = 3'd1;
    @(negedge i); ce = 1'b0;
    repeat (4) @(posedge i);
    #1 if (o !== 1'b0) begin $display("FAIL CE gate"); errors++; end
    @(negedge i); ce = 1'b1;
    rises = 0;
    repeat (8) @(posedge i);
    #1 if (rises < 3) begin $display("FAIL CE release"); errors++; end

    // CLR holds the output low at once
    @(posedge i); #1;
    clr = 1'b1; #0.1 if (o !== 1'b0) begin $display("FAIL CLR"); errors++; end
    clr = 1'b0;
    if (errors == 0) $display("PASS");
    $finish;
  end
endmodule
