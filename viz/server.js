// viz/server.js - live circuit viewer for the ws_array design
//
// Runs the real Verilog simulation (iverilog + vvp), reads the VCD it writes,
// turns it into one frame per clock cycle and serves a browser view.
// Saving any .v file in the project root re-runs the simulation and pushes
// the new result to the open page (Server-Sent Events).
//
// Uses only Node.js built-in modules.  Start:  node viz/server.js
// Then open http://localhost:8090

const http = require('http');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.PORT) || 8090;
const SOURCES = ['pkt_decoder.v', 'ws_cell.v', 'ws_array.v', 'tb.v'];
const VCD = path.join(ROOT, 'tb.vcd');
const SIM_CMD = `iverilog -g2012 -o sim ${SOURCES.join(' ')} && vvp -n sim`;

let result = { version: 0, ok: false, running: false, log: 'Not run yet.', frames: [] };
let running = false, rerun = false;
const clients = new Set();

// ---------------------------------------------------------------- VCD parsing

// Returns { signals: Map(fullName -> {width, changes: [[time, value], ...]}) }
// Only names accepted by keep() are stored.
function parseVcd(text, keep) {
    const byId = new Map();          // id code -> array of signal records
    const signals = new Map();
    const scope = [];
    let time = 0;
    let i = 0;
    const tokens = text.split(/\s+/);

    // Header
    while (i < tokens.length) {
        const tk = tokens[i++];
        if (tk === '$scope') { i++; scope.push(tokens[i++]); }
        else if (tk === '$upscope') { scope.pop(); }
        else if (tk === '$var') {
            const width = Number(tokens[i + 1]);
            const id = tokens[i + 2];
            const name = scope.concat(tokens[i + 3]).join('.');
            i += 4;
            if (keep(name)) {
                const rec = { width, changes: [] };
                signals.set(name, rec);
                if (!byId.has(id)) byId.set(id, []);
                byId.get(id).push(rec);
            }
        }
        else if (tk === '$enddefinitions') break;
    }

    const push = (id, v) => {
        const recs = byId.get(id);
        if (!recs) return;
        for (const r of recs) r.changes.push([time, v]);
    };

    // Value changes
    for (; i < tokens.length; i++) {
        const tk = tokens[i];
        if (!tk) continue;
        const c = tk[0];
        if (c === '#') time = Number(tk.slice(1));
        else if (c === 'b' || c === 'B') {
            const bits = tk.slice(1);
            const id = tokens[++i];
            push(id, /[xz]/i.test(bits) ? null : parseInt(bits, 2));
        }
        else if (c === '0' || c === '1') push(tk.slice(1), c === '1' ? 1 : 0);
        else if (c === 'x' || c === 'X' || c === 'z' || c === 'Z') push(tk.slice(1), null);
        // $dumpvars / $end / r(eal) values are ignored
    }
    return signals;
}

// Value of a signal at time t (after all changes at t)
function valueAt(rec, t) {
    if (!rec) return null;
    const ch = rec.changes;
    let lo = 0, hi = ch.length - 1, ans = null;
    while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (ch[mid][0] <= t) { ans = ch[mid][1]; lo = mid + 1; } else hi = mid - 1;
    }
    return ans;
}

// ---------------------------------------------------------------- frames

const CELL_SIGS = ['acc', 'y', 'wmem', 'wg', 's5', 'sum'];
const TOP_SIGS = ['clk', 'rst', 'load', 'load_row', 'load_pk', 'en', 'start', 'last', 'grp', 'xv', 'y_valid'];

function buildFrames(text) {
    const keep = (n) =>
        /^tb\.[a-z_]+$/.test(n) && TOP_SIGS.includes(n.slice(3)) ||
        /^tb\.dut\.(ld_en|ld_row|ld_w)$/.test(n) ||
        /^tb\.dut\.dec\[\d+\]\.u\.w$/.test(n) ||
        new RegExp(`^tb\\.dut\\.neuron\\[\\d+\\]\\.u\\.(${CELL_SIGS.join('|')})$`).test(n);
    const sig = parseVcd(text, keep);

    let N = 0, G = 0;
    for (const name of sig.keys()) {
        let m = name.match(/neuron\[(\d+)\]/); if (m) N = Math.max(N, Number(m[1]) + 1);
        m = name.match(/dec\[(\d+)\]/);        if (m) G = Math.max(G, Number(m[1]) + 1);
    }

    const clk = sig.get('tb.clk');
    const posedges = [];
    if (clk) for (let k = 1; k < clk.changes.length; k++)
        if (clk.changes[k][1] === 1 && clk.changes[k - 1][1] === 0) posedges.push(clk.changes[k][0]);
    if (clk && clk.changes.length && clk.changes[0][1] === 1) posedges.unshift(clk.changes[0][0]);

    const top = (n, t) => valueAt(sig.get('tb.' + n), t);
    const dut = (n, t) => valueAt(sig.get('tb.dut.' + n), t);
    const cell = (i, n, t) => valueAt(sig.get(`tb.dut.neuron[${i}].u.${n}`), t);

    const widths = {
        acc: sig.get('tb.dut.neuron[0].u.acc')?.width || 16,
        xv: sig.get('tb.xv')?.width || 40,
    };

    const frames = [];
    let token = -1, group = 0;
    for (let c = 0; c < posedges.length; c++) {
        const T = posedges[c];
        const pre = T - 1;               // inputs and combinational values this cycle
        const f = {
            cycle: c, time: T,
            rst: top('rst', pre), load: top('load', pre), load_row: top('load_row', pre),
            load_pk: top('load_pk', pre), en: top('en', pre), start: top('start', pre),
            last: top('last', pre), grp: top('grp', pre), xv: top('xv', pre),
            y_valid: top('y_valid', T),
            ld_en: dut('ld_en', pre), ld_row: dut('ld_row', pre), ld_w: dut('ld_w', pre),
            dec: [], acc_old: [], acc: [], y: [], wmem: [], wg: [], s5: [], sum: [],
        };
        for (let g = 0; g < G; g++) f.dec.push(dut(`dec[${g}].u.w`, pre));
        for (let i = 0; i < N; i++) {
            f.acc_old.push(cell(i, 'acc', pre));
            f.acc.push(cell(i, 'acc', T));
            f.y.push(cell(i, 'y', T));
            f.wmem.push(cell(i, 'wmem', T));
            f.wg.push(cell(i, 'wg', pre));
            f.s5.push(cell(i, 's5', pre));
            f.sum.push(cell(i, 'sum', pre));
        }
        if (f.en && f.start) { token++; group = 0; } else if (f.en) group++;
        f.token = f.en ? token : null;
        f.group = f.en ? group : null;
        frames.push(f);
    }
    return { N, G, widths, frames };
}

// ---------------------------------------------------------------- simulation

function broadcast(event, data) {
    const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of clients) res.write(msg);
}

function runSim(reason) {
    if (running) { rerun = true; return; }
    running = true;
    broadcast('running', { reason });
    const t0 = Date.now();
    exec(SIM_CMD, { cwd: ROOT, maxBuffer: 64 * 1024 * 1024, windowsHide: true }, (err, stdout, stderr) => {
        const log = (stdout || '') + (stderr || '');
        const next = { version: result.version + 1, reason, ok: !err, log, ms: 0, frames: result.frames,
                       N: result.N, G: result.G, widths: result.widths };
        if (!err) {
            try {
                Object.assign(next, buildFrames(fs.readFileSync(VCD, 'utf8')));
                next.passed = /ALL CHECKS PASSED/.test(log);
            } catch (e) {
                next.ok = false;
                next.log += '\n[viz] Could not read tb.vcd: ' + e.message;
            }
        }
        next.ms = Date.now() - t0;
        result = next;
        running = false;
        console.log(`[viz] run #${result.version} (${reason}): ${result.ok ? 'ok' : 'FAILED'}, ` +
                    `${result.frames.length} cycles, ${result.ms} ms`);
        broadcast('update', { version: result.version, ok: result.ok, reason });
        if (rerun) { rerun = false; runSim('queued change'); }
    });
}

// Re-run when a Verilog source in the project root is saved
let debounce = null;
fs.watch(ROOT, (ev, file) => {
    if (!file || !/\.v$/.test(file)) return;
    clearTimeout(debounce);
    debounce = setTimeout(() => runSim(`${file} changed`), 300);
});

// ---------------------------------------------------------------- HTTP

const server = http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/' || url === '/index.html') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        fs.createReadStream(path.join(__dirname, 'index.html')).pipe(res);
    }
    else if (url === '/data') {
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end(JSON.stringify(result));
    }
    else if (url === '/run' && req.method === 'POST') {
        runSim('run button');
        res.writeHead(202); res.end();
    }
    else if (url === '/events') {
        res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
        res.write(`event: hello\ndata: ${JSON.stringify({ version: result.version, running })}\n\n`);
        clients.add(res);
        req.on('close', () => clients.delete(res));
    }
    else { res.writeHead(404); res.end('not found'); }
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`[viz] Live circuit view: http://localhost:${PORT}`);
    console.log(`[viz] Watching ${ROOT} for .v changes`);
    runSim('startup');
});
