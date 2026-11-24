# AI chip design: learning/research project

## Goal
Design a compute unit for AI workloads (matrix-vector products) that uses less
energy and delivers more throughput. Currently in the learning and measurement
phase: small Verilog circuits, simulated and measured. See README.md for ideas,
results and the version history.

## Status
- v1 (MAC vs ternary MAC, 4-neuron layer): verified, archived locally.
- v2 (weight-stationary, packing, zero skipping): verified, archived locally.
- v3 (64 neurons x 20 inputs x 100 tokens, shared decoder, 5 lanes): verified.
- Next candidates: systolic array, 4-bit inputs, double-buffered weights.

## Working rules
- All repository content is in English: module/signal names, comments,
  README, $display text.
- Chat explanations to the maintainer: Turkish, simple, with software
  analogies (the maintainer is new to Verilog, strong software background).
- Testbenches check themselves against a software reference and print
  "RESULT: ALL CHECKS PASSED".
- Current files have no version suffix (ws_cell.v, ws_array.v, tb.v). When a
  file is replaced by a new version, the old one moves to `archive/vN/` with a
  `_vN` suffix (e.g. archive/v3/ws_cell_v3.v). `archive/` is git-ignored.
- List the changed files after every change.

## Environment
- Windows + VS Code, extension: mshr-h.veriloghdl
- OSS CAD Suite in `oss-cad-suite/` (git-ignored), `bin` and `lib` on PATH
- Yosys does not run under Git Bash (exit code 127); use PowerShell or cmd
- No Graphviz and no Python installed; Node.js is installed
- Live viewer: `node viz/server.js` -> http://localhost:8090 (built-in modules
  only; reads signals by name from tb.vcd, so update viz/ if they are renamed)
- Tasks in `.vscode/tasks.json` (Ctrl+Shift+B = simulation), run via cmd.exe
- iverilog needs `-g2012` for v3 (`$clog2` in parameters)
- `cell` is a reserved word in Verilog; do not use it as a block name
