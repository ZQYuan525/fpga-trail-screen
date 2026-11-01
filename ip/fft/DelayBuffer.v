//----------------------------------------------------------------------
//  DelayBuffer: Generate Constant Delay
//----------------------------------------------------------------------
module DelayBuffer #(
    parameter   DEPTH = 32,
    parameter   WIDTH = 16
)(
    input               clock,  //  Master Clock
    input               reset,  // Local adaptation: initialize circular RAM pointer
    input   [WIDTH-1:0] di_re,  //  Data Input (Real)
    input   [WIDTH-1:0] di_im,  //  Data Input (Imag)
    output  [WIDTH-1:0] do_re,  //  Data Output (Real)
    output  [WIDTH-1:0] do_im   //  Data Output (Imag)
);

generate if(DEPTH>=8) begin: ram_delay
    // Power-of-two ring. Read the slot after the current write slot; registered
    // output preserves exactly DEPTH clocks without a read/write collision.
    localparam AW=$clog2(DEPTH);
    reg [AW-1:0] pointer;
    wire [AW-1:0] next_pointer=pointer+1'b1;
    reg [2*WIDTH-1:0] memory[0:DEPTH-1]; /* fehdl force_ram=1, ram_style="bram" */
    reg [2*WIDTH-1:0] delayed;
    always @(posedge clock or posedge reset)
        if(reset) pointer<=0;else pointer<=next_pointer;
    always @(posedge clock) begin
        memory[pointer]<={di_re,di_im};
        delayed<=memory[next_pointer];
    end
    assign {do_re,do_im}=delayed;
end else begin: shift_delay
reg [WIDTH-1:0] buf_re[0:DEPTH-1];
reg [WIDTH-1:0] buf_im[0:DEPTH-1];
integer n;

//  Shift Buffer
always @(posedge clock) begin
    for (n = DEPTH-1; n > 0; n = n - 1) begin
        buf_re[n] <= buf_re[n-1];
        buf_im[n] <= buf_im[n-1];
    end
    buf_re[0] <= di_re;
    buf_im[0] <= di_im;
end

assign  do_re = buf_re[DEPTH-1];
assign  do_im = buf_im[DEPTH-1];
end endgenerate

endmodule
