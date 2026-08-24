// Minimal design whose only purpose is to reach write_bitstream.
module tiny(input clk, input a, output reg y);
  always @(posedge clk) y <= ~a;
endmodule
