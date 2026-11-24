# AI chip experiments: ternary, weight-stationary matrix-vector unit

A learning/research project: designing a compute unit that runs AI workloads
(matrix-vector products) with less energy and higher throughput. Small
circuits are written in Verilog, simulated with Icarus Verilog and measured
with Yosys.

## Key ideas
- Most energy goes into **moving data**, not computing (the memory wall).
- **Ternary weights** (-1/0/+1, BitNet style): no multipliers, only add/subtract.
- **Zero skipping**: a weight of 0 means that lane does no work
  (clock gating / operand isolation in a real chip).
- **Weight-stationary**: weights stay inside the cells and tokens stream
  through, so weight traffic is paid once.
- **Packing**: 5 ternary weights fit in 1 byte (3^5 = 243 <= 256), so a weight
  costs 1.6 bits.

## Current version: v3
| File | Purpose |
|---|---|
| `pkt_decoder.v` | Shared packet decoder: 1 byte -> 5 ternary weights |
| `ws_cell.v` | One neuron: stores its weights, processes 5 inputs per cycle |
| `ws_array.v` | Layer of N neurons with G shared decoders and a pipeline register |
| `tb.v` | Self-checking testbench: 64 neurons x 20 inputs, 100 tokens |
| `tb.gtkw` | GTKWave view with the most useful signals |

```
 packed bytes --> [4 x pkt_decoder] --> [pipeline reg] --> row select --+
                                                                        v
 x (5 inputs/cycle) ---------------------------------> [neuron 0 .. neuron 63]
                                                              |
                                                          y (per token)
```

What changed from v2:
1. **Shared decoder**: 4 decoders for the whole array instead of one per cell
   (a per-cell design would need 256 for this layer).
2. **5 inputs per cycle** per neuron (5 lanes): 400 compute cycles instead of 2000.
3. **No gaps between tokens**: results are latched into `y`, so the next token
   starts immediately.
4. **Narrow adders**: 11-bit lane sum, 16-bit accumulator.
5. **Pipelined loading**: the decoder output is registered so the decoder does
   not sit on the same clock cycle as anything else.

## Results (v3)
```
Size            : 64 neurons x 20 inputs, 100 tokens
Time            : 465 cycles (65 load + 400 compute)
v2 method       : 2000 compute cycles (1 input/cycle)
Term operations : 128000 (active 85800, gated 42200 = weight 0)
Multiplications : 0   (classic method: 128000)
Packet decoders : 4 (one per cell would be: 256)
Bits moved v1   : 1040000
Bits moved v3   : 18048  (weights 2048 + inputs 16000)
Checks          : 6400 results
RESULT: ALL CHECKS PASSED
```

## Gate counts (Yosys 0.71, generic `synth`)
"Depth" is the longest combinational path in gate levels (`ltp -noff`), a
rough proxy for the achievable clock rate. Cell counts are generic gates,
not real silicon area.

| Design | Cells | Flip-flops | Depth | Inputs/cycle |
|---|---|---|---|---|
| `mac` (8x8 multiplier, v1) | 651 | 20 | - | 1 |
| `ternary_mac` (v1) | 150 | 20 | - | 1 |
| `ws_cell` v2 (5 weights, decoder + counters inside) | 489 | 62 | 43 | 1 |
| `ws_cell` v2 without counters | 387 | 30 | 41 | 1 |
| `pkt_decoder` | 111 | 0 | 24 | - |
| `ws_cell` v3 (20 weights, 5 lanes) | 560 | 72 | 43 | 5 |
| `ws_array` v3, N=64 | 34005 | 4656 | - | 5 per neuron |

Takeaways:
- Dropping the multiplier makes the cell 4.3x smaller (651 -> 150).
- A v3 cell does 5x the work per cycle of a v2 cell at the same logic depth
  (43), for about 1.45x the cells of a counter-free v2 cell (560 vs 387),
  while also storing 4x as many weights.
- The 4 shared decoders are 444 cells, about 1.3% of the 64-neuron array.
  One decoder per cell would add about 28,000 cells and nearly double it.
- The 243-entry lookup-table decoder (tried during v2) was larger (580 cells
  for the cell) than arithmetic decoding, because Yosys turns it into random
  logic. A table only pays off as a real ROM.

## Version history
- **v1**: classic 8x8 MAC vs multiplier-free ternary MAC, one neuron; then a
  4-neuron layer with operation counters.
- **v2**: weight-stationary cell with packed weights and zero skipping,
  4 neurons x 5 inputs, 3 tokens. Weight traffic dropped from 600 to 152 bits.
- **v3**: scaled up to 64 x 20 x 100 with a shared decoder and 5 lanes (above).

## Setup (Windows)
Install **[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)**
(iverilog, yosys, gtkwave in one package):
1. Download the `windows-x64` file from the
   [Releases page](https://github.com/YosysHQ/oss-cad-suite-build/releases)
2. Extract it, e.g. into the project folder as `oss-cad-suite/` (git-ignored)
3. Add its `bin` and `lib` folders to PATH and restart VS Code
4. Check: `iverilog -V` and `yosys -V`

Use PowerShell or cmd: the Yosys wrapper does not run under Git Bash.
On Linux: `sudo apt install iverilog gtkwave yosys`

## Running
In VS Code: **Ctrl+Shift+B** runs the v3 simulation; other tasks are under
**Tasks: Run Task**. From a terminal:

    iverilog -g2012 -o sim pkt_decoder.v ws_cell.v ws_array.v tb.v
    vvp -n sim

Gate counts:

    yosys -p "read_verilog -sv pkt_decoder.v ws_cell.v; synth -top ws_cell; stat; ltp -noff"

## Viewing the circuit
- **Live circuit view** (needs only Node.js, no packages):

      node viz/server.js

  then open http://localhost:8090. The server runs the real simulation,
  turns `tb.vcd` into one frame per clock cycle and shows the array as a
  diagram: packed bytes and decoders lighting up while weights load, the
  5-input bus, and all 64 neurons with their accumulators and the +/-/gated
  state of each lane. Play, pause or step cycle by cycle; click a neuron to
  see its stored weights and the lane-by-lane sum. Saving any `.v` file
  re-runs the simulation and the page updates by itself.
  In VS Code: **Tasks: Run Task -> Live circuit view**.
- **Waveforms**: `gtkwave tb.gtkw` opens `tb.vcd` with load, compute and
  neuron 0/1 accumulator signals already arranged.
- **Schematic (local)**: `yosys -p "read_verilog -sv ws_cell.v; proc; opt; show"`
  needs Graphviz installed. Alternatively export JSON with
  `write_json cell.json` and render it with
  [netlistsvg](https://github.com/nturley/netlistsvg).
- **Interactive (browser)**: paste a module into
  [DigitalJS](https://digitaljs.tilk.eu/) to see and simulate its circuit.

## Next steps
- Systolic array (TPU-style data flow between neighbouring cells)
- 4-bit inputs (check accuracy in software first)
- Double-buffered weights so loading overlaps with compute
- Compute-in-memory ideas
