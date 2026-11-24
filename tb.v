// tb.v - v3 testbench: 64 neurons x 20 inputs, 100 tokens, shared decoder, 5 inputs/cycle
// Weights and inputs are pseudo-random with a fixed seed; for every token the
// outputs of all 64 neurons are checked against a software reference.
// Requires: pkt_decoder.v, ws_cell.v, ws_array.v

`timescale 1ns/1ps

module tb;
    localparam N    = 64;      // neurons
    localparam G    = 4;       // groups of 5 inputs
    localparam K    = 5*G;     // inputs per neuron (20)
    localparam T    = 100;     // tokens
    localparam ACCW = 16;

    reg clk = 0, rst = 1, load = 0, en = 0, start = 0, last = 0;
    always #5 clk = ~clk;

    reg  [5:0]        load_row;
    reg  [8*G-1:0]    load_pk;
    reg  [1:0]        grp;
    reg  [39:0]       xv;
    wire [N*ACCW-1:0] y_flat;
    wire              y_valid;

    ws_array #(.N(N), .G(G), .ACCW(ACCW)) dut (
        .clk(clk), .rst(rst), .load(load), .load_row(load_row), .load_pk(load_pk),
        .en(en), .start(start), .last(last), .grp(grp), .xv(xv),
        .y_flat(y_flat), .y_valid(y_valid)
    );

    reg signed [7:0] W [0:N*K-1];   // W[neuron*K + input], -1/0/+1
    reg signed [7:0] X [0:T*K-1];   // X[token*K + input]
    reg        [7:0] P [0:N*G-1];   // packed weights
    reg signed [ACCW-1:0] yn;
    integer seed, n, i, t, g, d, mul, r, b;
    integer load_cycles, comp_cycles, errors, checks, nz, zero;
    integer bits_v1, bits_v3;

    initial begin
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);

        // Generate data
        seed = 2026; nz = 0; zero = 0;
        for (i = 0; i < N*K; i = i + 1) begin
            W[i] = ({$random(seed)} % 3) - 1;
            if (W[i] == 0) zero = zero + 1; else nz = nz + 1;
        end
        for (i = 0; i < T*K; i = i + 1)
            X[i] = $random(seed);                  // -128..127

        // Pack 5 weights into 1 byte (in software, once)
        for (b = 0; b < N*G; b = b + 1) begin
            P[b] = 0; mul = 1;
            for (i = 0; i < 5; i = i + 1) begin
                d = (W[b*5+i] == 1) ? 1 : (W[b*5+i] == -1) ? 2 : 0;
                P[b] = P[b] + d * mul;
                mul = mul * 3;
            end
        end

        load_row = 0; load_pk = 0; grp = 0; xv = 0;
        load_cycles = 0; comp_cycles = 0; errors = 0; checks = 0;

        // 1) Load: one neuron's 4 bytes per cycle
        @(negedge clk); rst = 0;
        for (n = 0; n < N; n = n + 1) begin
            load = 1; load_row = n;
            load_pk = {P[n*G+3], P[n*G+2], P[n*G+1], P[n*G+0]};
            @(negedge clk); load_cycles = load_cycles + 1;
        end
        load = 0;
        @(negedge clk); load_cycles = load_cycles + 1;   // drain pipeline register

        // 2) Compute: tokens back to back, no gaps
        for (t = 0; t < T; t = t + 1) begin
            for (g = 0; g < G; g = g + 1) begin
                b = t*K + g*5;
                en = 1; start = (g == 0); last = (g == G-1); grp = g;
                xv = {X[b+4], X[b+3], X[b+2], X[b+1], X[b]};
                @(negedge clk); comp_cycles = comp_cycles + 1;
            end

            // The last group was just computed: y now holds token t's result
            if (!y_valid) errors = errors + 1;
            for (n = 0; n < N; n = n + 1) begin
                r = 0;
                for (i = 0; i < K; i = i + 1) r = r + W[n*K+i] * X[t*K+i];
                yn = y_flat[n*ACCW +: ACCW];
                checks = checks + 1;
                if (yn != r) begin
                    errors = errors + 1;
                    if (errors <= 5)
                        $display("ERROR token %0d neuron %0d: chip=%0d reference=%0d", t, n, yn, r);
                end
                if (t < 2 && n < 6)
                    $display("Token %0d neuron %0d: chip=%0d  reference=%0d", t, n, yn, r);
            end
        end
        en = 0; start = 0; last = 0;

        bits_v1 = T*N*K*8 + T*K*8;   // v1: 8-bit weight read on every use
        bits_v3 = N*G*8   + T*K*8;   // v3: packed weights read once

        $display("-------------------------------------------");
        $display("Size            : %0d neurons x %0d inputs, %0d tokens", N, K, T);
        $display("Time            : %0d cycles (%0d load + %0d compute)",
                 load_cycles + comp_cycles, load_cycles, comp_cycles);
        $display("v2 method       : %0d compute cycles (1 input/cycle)", T*K);
        $display("Term operations : %0d (active %0d, gated %0d = weight 0)",
                 T*N*K, T*nz, T*zero);
        $display("Multiplications : 0   (classic method: %0d)", T*N*K);
        $display("Packet decoders : %0d (one per cell would be: %0d)", G, N*G);
        $display("Bits moved v1   : %0d", bits_v1);
        $display("Bits moved v3   : %0d  (weights %0d + inputs %0d)", bits_v3, N*G*8, T*K*8);
        $display("Checks          : %0d results", checks);
        if (errors == 0) $display("RESULT: ALL CHECKS PASSED");
        else             $display("RESULT: %0d ERRORS", errors);
        $finish;
    end
endmodule
