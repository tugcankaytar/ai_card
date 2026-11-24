// ws_array.v - layer (v3) of N neurons x (5*G) inputs
//
//   packed bytes --> [G x pkt_decoder] --> [pipeline register] --> N cells
//                                                (row select)
//   x (5 inputs/cycle) ---------------------------------------> all cells
//
// Loading: one neuron's full weight row (G bytes) per cycle.
//   Decoder count = G, independent of N. With a decoder per cell (v2 style)
//   it would be N*G.
// The decoder output goes through a register (pipeline stage), so the
//   decoder's long logic path does not share a clock cycle with anything
//   else and does not limit the clock rate. Cost: loading takes 1 extra cycle.
// Compute: each cycle 5 inputs are broadcast to all neurons; a token takes
//   G cycles, and tokens follow each other with no gaps.

module ws_array #(
    parameter N    = 64,
    parameter G    = 4,
    parameter ACCW = 16,
    parameter RW   = (N > 1) ? $clog2(N) : 1,
    parameter GW   = (G > 1) ? $clog2(G) : 1
) (
    input                   clk,
    input                   rst,
    input                   load,        // 1 = load row load_row
    input  [RW-1:0]         load_row,
    input  [8*G-1:0]        load_pk,     // the row's G packed bytes
    input                   en,
    input                   start,
    input                   last,
    input  [GW-1:0]         grp,
    input  [39:0]           xv,
    output [N*ACCW-1:0]     y_flat,      // neuron n: y_flat[n*ACCW +: ACCW]
    output reg              y_valid      // 1 cycle pulse: new token result ready
);

    // 1) Shared decoders
    wire [10*G-1:0] dec_w;
    genvar g;
    generate
        for (g = 0; g < G; g = g + 1) begin : dec
            pkt_decoder u (.pk(load_pk[8*g +: 8]), .w(dec_w[10*g +: 10]));
        end
    endgenerate

    // 2) Pipeline register: decoded row + address wait one cycle
    reg [10*G-1:0] ld_w;
    reg [RW-1:0]   ld_row;
    reg            ld_en;
    always @(posedge clk) begin
        ld_w    <= dec_w;
        ld_row  <= load_row;
        ld_en   <= rst ? 1'b0 : load;
        y_valid <= rst ? 1'b0 : (en && last);
    end

    // 3) Neuron cells
    genvar n;
    generate
        for (n = 0; n < N; n = n + 1) begin : neuron
            ws_cell #(.G(G), .ACCW(ACCW)) u (
                .clk(clk), .rst(rst),
                .load_en(ld_en && (ld_row == n)), .load_w(ld_w),
                .en(en), .start(start), .last(last), .grp(grp), .xv(xv),
                .y(y_flat[n*ACCW +: ACCW])
            );
        end
    endgenerate

endmodule
