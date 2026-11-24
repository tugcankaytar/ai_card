// pkt_decoder.v - shared packet decoder
//
// Unpacks 1 byte (base-3, 5 digits) into 5 two-bit ternary weight codes:
//   digit 0 -> 2'd0 (0),  digit 1 -> 2'd1 (+1),  digit 2 -> 2'd2 (-1)
//
// In v2 every cell had its own decoder, used only while loading weights.
// In v3 the decoder sits at the edge of the array and is shared by all cells.
//
// Successive division is used: each step divides a smaller number, which
// needs fewer gates than independent "pk/81 % 3" style divisions
// (Yosys: 111 cells vs 145 cells).

module pkt_decoder (
    input  [7:0] pk,   // packed byte (0..242)
    output [9:0] w     // w[2i+1:2i] = code of weight i
);
    wire [6:0] q1 = pk / 3;
    wire [4:0] q2 = q1 / 3;
    wire [3:0] q3 = q2 / 3;
    wire [1:0] q4 = q3 / 3;

    assign w[1:0] = pk - 3*q1;
    assign w[3:2] = q1 - 3*q2;
    assign w[5:4] = q2 - 3*q3;
    assign w[7:6] = q3 - 3*q4;
    assign w[9:8] = q4;
endmodule
