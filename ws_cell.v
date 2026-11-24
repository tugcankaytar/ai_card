// ws_cell.v - one neuron (v3), 5 inputs per cycle
//
// Changes from v2:
//  1) No packet decoder inside the cell; weights arrive already decoded
//     (decoder: pkt_decoder.v, shared at the edge of the array).
//  2) 5 inputs are processed per cycle (5 "lanes") instead of 1,
//     like unrolling a loop by 5.
//  3) The result is copied into a separate y register, so the next token
//     can start immediately (no bubbles between tokens).
//  4) Narrow adders: the sum of 5 terms is at most 5*128 = 640, so 11 bits
//     are enough. The accumulator is ACCW bits wide (default 16).
//
// A lane whose weight is 0 adds 0. In a real chip that lane's inputs would
// be frozen (operand isolation) so its gates do not toggle and burn energy;
// this is the per-lane version of v2's "gated cell".

module ws_cell #(
    parameter G    = 4,                          // number of groups (inputs = 5*G)
    parameter ACCW = 16,                         // accumulator width
    parameter GW   = (G > 1) ? $clog2(G) : 1     // group index width
) (
    input                        clk,
    input                        rst,
    input                        load_en,        // 1 = write this neuron's weights
    input         [10*G-1:0]     load_w,         // decoded weight row
    input                        en,             // 1 = compute
    input                        start,          // first group of a token
    input                        last,           // last group of a token
    input         [GW-1:0]       grp,            // which 5-input group this cycle
    input         [39:0]         xv,             // 5 inputs x 8 bits
    output reg signed [ACCW-1:0] y               // result of the finished token
);

    reg        [10*G-1:0] wmem;   // 5*G weights, 2 bits each
    reg signed [ACCW-1:0] acc;

    wire [9:0] wg = wmem[grp*10 +: 10];   // the 5 weights of this group

    // One lane: +x, -x or 0 depending on the weight code (no multiplier)
    function signed [10:0] term;
        input [1:0]        d;
        input signed [7:0] x;
        case (d)
            2'd1:    term =  x;
            2'd2:    term = -x;
            default: term =  0;
        endcase
    endfunction

    wire signed [10:0] s5 = term(wg[1:0], xv[ 7: 0]) + term(wg[3:2], xv[15: 8])
                          + term(wg[5:4], xv[23:16]) + term(wg[7:6], xv[31:24])
                          + term(wg[9:8], xv[39:32]);

    wire signed [ACCW-1:0] base = start ? {ACCW{1'b0}} : acc;
    wire signed [ACCW-1:0] sum  = base + s5;

    always @(posedge clk) begin
        if (load_en)
            wmem <= load_w;          // weight memory: no reset needed

        if (rst) begin
            acc <= 0;
            y   <= 0;
        end
        else if (en) begin
            acc <= sum;
            if (last) y <= sum;
        end
    end

endmodule
