// Check that the committed page data matches a fresh export.
//
//   node check-data.mjs <committed data.js> <fresh data.js>
//
// Two kinds of dataset, two standards:
//
//   EXACT  - produced only by integer arithmetic and the seeded generator (the
//            order book, simulator, market maker, ETF market, replay). These
//            are identical bit for bit on Windows and Linux, and must stay so.
//
//   NUMERIC - computed with exp, log, erfc and iterative fits (options, hedging,
//            risk, the ETF basket). The system maths library differs in the last
//            bits between platforms, and the SVI fit amplifies that, so these
//            are compared to a tolerance: |a - b| <= abs_tol + rel_tol * max(|a|, |b|).
//
// Measured on a Windows build against a Linux CI runner, the worst relative
// differences were 2e-7 (surface), 7e-14 (hedging), 6e-15 (risk). The tolerance
// below is 1e-5, about 50x the worst, and still far below any real change.

import { readFileSync } from "node:fs";

const EXACT = new Set(["backtest", "informed_sweep", "gamma_sweep", "replay", "seeds", "etf_market"]);
const REL_TOL = 1e-5;
const ABS_TOL = 1e-12; // values that are mathematically zero come out as rounding noise

function load(path) {
  const s = readFileSync(path, "utf8");
  return JSON.parse(s.slice(s.indexOf("=") + 1).trim().replace(/;$/, ""));
}

function compare(a, b, path, exact, out) {
  if (typeof a !== typeof b) return out.push(`${path}: type ${typeof a} vs ${typeof b}`);
  if (a === null || b === null) return a === b || out.push(`${path}: ${a} vs ${b}`);
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return out.push(`${path}: length ${a.length} vs ${b?.length}`);
    return a.forEach((x, i) => compare(x, b[i], `${path}[${i}]`, exact, out));
  }
  if (typeof a === "object") {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const k of keys) {
      if (!(k in a) || !(k in b)) out.push(`${path}.${k}: present in only one`);
      else compare(a[k], b[k], `${path}.${k}`, exact, out);
    }
    return;
  }
  if (typeof a === "number") {
    if (a === b) return;
    if (exact) return out.push(`${path}: ${a} vs ${b} (must be identical)`);
    const tol = ABS_TOL + REL_TOL * Math.max(Math.abs(a), Math.abs(b));
    if (!(Math.abs(a - b) <= tol)) out.push(`${path}: ${a} vs ${b} (beyond tolerance)`);
    return;
  }
  if (a !== b) out.push(`${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
}

const [committedPath, freshPath] = process.argv.slice(2);
if (!committedPath || !freshPath) {
  console.error("usage: node check-data.mjs <committed data.js> <fresh data.js>");
  process.exit(2);
}
const committed = load(committedPath);
const fresh = load(freshPath);

let failed = 0;
const names = new Set([...Object.keys(committed), ...Object.keys(fresh)]);
for (const name of [...names].sort()) {
  if (!(name in committed) || !(name in fresh)) {
    console.log(`FAIL  ${name}: missing from one side`);
    failed++;
    continue;
  }
  const exact = EXACT.has(name);
  const problems = [];
  compare(committed[name], fresh[name], name, exact, problems);
  if (problems.length) {
    failed++;
    console.log(`FAIL  ${name} (${exact ? "exact" : "tolerance"}): ${problems.length} differences`);
    problems.slice(0, 4).forEach((p) => console.log("        " + p.slice(0, 150)));
  } else {
    console.log(`ok    ${name} (${exact ? "identical" : "within tolerance"})`);
  }
}
process.exit(failed ? 1 : 0);
