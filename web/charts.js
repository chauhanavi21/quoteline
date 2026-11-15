// Every chart on the page. Each reads the OCaml export in window.QUOTELINE.
// Series colours follow the entity, not the rank: spread capture is always
// --c1, adverse selection --c2, inventory --c3, wherever they appear.

import {
  html, el, frame, linear, niceTicks, fmt, axisFormat, line, area, roundedBar, roundedBarH,
  endDot, endLabel, crosshair, legend, tableView, wireToggle, onVisible, trigger, countUp, reduced,
} from "./viz.js";

const money = (v) => (v < 0 ? "-" : "") + Math.abs(v).toFixed(2);

// ---- card scaffold ------------------------------------------------------

function card(parent, { title, sub, delay = 0 }) {
  const c = html("div", { class: "card reveal", "data-view": "chart", style: `--i:${delay}` }, parent);
  const header = html("header", {}, c);
  const t = html("div", {}, header);
  html("h3", { text: title }, t);
  if (sub) html("p", { class: "sub", text: sub }, t);
  html("button", { class: "view-toggle", type: "button", "aria-pressed": "false", text: "Table view" }, header);
  const chart = html("div", { class: "chart" }, c);
  const tbl = html("div", { class: "tbl" }, chart);
  const lg = html("div", { class: "legend" }, c);
  wireToggle(c);
  return { c, chart, tbl, lg };
}

// ---- hero stats ---------------------------------------------------------

export function heroStats(d) {
  const host = document.getElementById("hero-stats");
  const b = d.backtest.summary;
  const items = [
    { label: "Order book events replayed", to: d.replay.events.length, fmt: (v) => Math.round(v).toLocaleString(), note: "real engine output" },
    { label: "Market-maker fills", to: b.fills, fmt: (v) => Math.round(v).toLocaleString(), note: `${b.volume.toLocaleString()} lots traded` },
    { label: "Hedging error, 504 vs 12 trades", to: d.hedging.scaling[0].std_pnl / d.hedging.scaling[5].std_pnl, fmt: (v) => v.toFixed(1) + "x smaller", note: "measured; pure 1/sqrt(n) scaling would give 6.5x" },
    { label: "Worst volatility-slice fit", to: Math.max(...d.surface.slices.map((s) => s.fit_rmse_variance)) * 1e5, fmt: (v) => v.toFixed(0) + " per 100,000", note: "RMSE in total variance; smaller is better" },
  ];
  items.forEach((it, i) => {
    const s = html("div", { class: "stat reveal", style: `--i:${i + 4}` }, host);
    html("div", { class: "label", text: it.label }, s);
    const v = html("div", { class: "value", text: "0" }, s);
    html("div", { class: "note", text: it.note }, s);
    onVisible(s, () => countUp(v, it.to, it.fmt), 0.6);
  });
}

// ---- market maker -------------------------------------------------------

export function makerSection(d) {
  const grid = document.getElementById("maker-grid");
  const s = d.backtest.summary;

  // 1. PnL breakdown: three bars from a zero baseline, then the total.
  {
    const { c, chart, tbl, lg } = card(grid, { title: "Where the PnL comes from", sub: "Currency units, one 20,000-event run", delay: 0 });
    const parts = [
      { name: "Spread capture", v: s.spread_capture, color: "var(--c1)" },
      { name: "Adverse selection", v: s.adverse_selection, color: "var(--c2)" },
      { name: "Inventory", v: s.inventory, color: "var(--c3)" },
    ];
    const lo = Math.min(0, ...parts.map((p) => p.v), s.total_pnl);
    const hi = Math.max(0, ...parts.map((p) => p.v), s.total_pnl);
    const ticks = niceTicks(lo, hi, 5);
    const f = frame(chart, {
      width: 560, height: 310, margin: { top: 16, right: 24, bottom: 58, left: 48 },
      x: { domain: [0, 4], ticks: [] }, y: { domain: [ticks[0], ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      yZero: true,
    });
    const slot = f.pw / 4;
    const bw = 24;
    const all = [...parts, { name: "Total", v: s.total_pnl, color: "var(--seq-3)" }];
    all.forEach((p, i) => {
      const cx = slot * i + slot / 2;
      const y0 = f.sy(0);
      const y1 = f.sy(p.v);
      if (Math.abs(y1 - y0) > 0.5) roundedBar(f.layer, { x: cx - bw / 2, y0, y1, w: bw, fill: p.color });
      // A short bar cannot hold its label on the zero-facing side, so put it
      // above the line; never let it run into the category label row below.
      const short = Math.abs(y1 - y0) < 22;
      const room = f.ph - y1 > 34; // space below a negative bar for its label
      const ty = p.v >= 0 || short ? y1 - 8 : room ? y1 + 22 : y0 - 8;
      const t = el("text", { class: "end-label fade-in", x: cx, y: ty, "text-anchor": "middle" }, f.layer);
      t.textContent = (p.v >= 0 ? "+" : "") + money(p.v);
      // Category names wrap onto one line per word, so neighbours never collide.
      p.name.split(" ").forEach((word, k) => {
        const l = el("text", { class: "tick", x: cx, y: f.ph + 22 + k * 19, "text-anchor": "middle" }, f.g);
        l.textContent = word;
      });
      // per-bar tooltip via native title as a no-JS fallback, plus focusable rect
      const hit = el("rect", { x: cx - slot / 2, y: 0, width: slot, height: f.ph, fill: "transparent", tabindex: 0 }, f.g);
      const title = el("title", {}, hit);
      title.textContent = `${p.name}: ${money(p.v)}`;
    });
    tableView(tbl, ["Component", "Value"], [...parts, { name: "Total", v: s.total_pnl }].map((p) => [p.name, money(p.v)]));
    lg.replaceChildren();
    onVisible(c, () => trigger(c));
  }

  // 2. Cumulative PnL and inventory: two charts (never a dual axis).
  {
    const { c, chart, tbl, lg } = card(grid, { title: "Mark-to-market PnL over the run", sub: "Currency units; each point is one thinned sample of the event stream", delay: 1 });
    const pts = d.backtest.pnl.map((v, i) => [i, v]);
    const ys = pts.map((p) => p[1]);
    const ticks = niceTicks(Math.min(...ys), Math.max(...ys), 5);
    const xt = niceTicks(0, pts.length - 1, 5).filter((t) => t >= 0 && t <= pts.length - 1);
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 14, right: 70, bottom: 34, left: 52 },
      x: { domain: [0, pts.length - 1], ticks: xt, format: (v) => `${Math.round((v / (pts.length - 1)) * d.backtest.events / 1000)}K` },
      y: { domain: [ticks[0], ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      xTitle: "events", yZero: true,
    });
    area(f.layer, pts, f.sx, f.sy, "var(--c1)", f.sy(0));
    line(f.layer, pts, f.sx, f.sy, "var(--c1)");
    const last = pts[pts.length - 1];
    endDot(f.layer, f.sx(last[0]), f.sy(last[1]), "var(--c1)");
    endLabel(f.layer, f.sx(last[0]), f.sy(last[1]), money(last[1]));
    crosshair(f, chart, {
      series: [{ name: "PnL", color: "var(--c1)", points: pts }], xs: pts.map((p) => p[0]),
      headFor: (x) => `event ${Math.round((x / (pts.length - 1)) * d.backtest.events).toLocaleString()}`,
      valueFor: (_, p) => money(p[1]),
    });
    tableView(tbl, ["Event", "PnL"], pts.filter((_, i) => i % 10 === 0).map((p) => [Math.round((p[0] / (pts.length - 1)) * d.backtest.events), money(p[1])]));
    lg.replaceChildren();
    onVisible(c, () => trigger(c));
  }

  // 3. Informed-flow sweep: two lines on one axis, per lot traded.
  {
    const rows = d.informed_sweep.rows;
    const { c, chart, tbl, lg } = card(grid, { title: "More informed flow, worse adverse selection", sub: "Per lot traded, averaged over four seeds", delay: 2 });
    const series = [
      { name: "Spread capture", color: "var(--c1)", points: rows.map((r) => [r.informed, r.spread_capture]), key: "spread_capture" },
      { name: "Adverse selection", color: "var(--c2)", points: rows.map((r) => [r.informed, r.adverse_selection]), key: "adverse_selection" },
    ];
    function draw(hidden = new Set()) {
      const vis = series.filter((s) => !hidden.has(s.name));
      const ys = vis.flatMap((s) => s.points.map((p) => p[1]));
      const ticks = niceTicks(Math.min(0, ...ys), Math.max(0, ...ys), 5);
      const f = frame(chart, {
        width: 560, height: 300, margin: { top: 14, right: 118, bottom: 38, left: 52 },
        x: { domain: [0, 1], ticks: [0, 0.2, 0.4, 0.6, 0.8, 1], format: (v) => `${Math.round(v * 100)}%` },
        y: { domain: [ticks[0], ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
        xTitle: "share of market orders that are informed", yTitle: "currency per lot traded", yZero: true,
      });
      vis.forEach((s) => {
        line(f.layer, s.points, f.sx, f.sy, s.color);
        const l = s.points[s.points.length - 1];
        endDot(f.layer, f.sx(l[0]), f.sy(l[1]), s.color);
        endLabel(f.layer, f.sx(l[0]), f.sy(l[1]), `${s.name.split(" ")[0]} ${money(l[1])}`);
      });
      crosshair(f, chart, {
        series: vis, xs: rows.map((r) => r.informed),
        headFor: (x) => `${Math.round(x * 100)}% informed`, valueFor: (_, p) => money(p[1]) + " / lot",
      });
      trigger(chart);
    }
    legend(lg, series, draw);
    draw();
    tableView(tbl, ["Informed", "Lots", "Spread", "Adverse", "Total"], rows.map((r) => [`${Math.round(r.informed * 100)}%`, r.volume, money(r.spread_capture), money(r.adverse_selection), money(r.total)]));
    onVisible(c, () => trigger(c));
  }

  // 4. Gamma sweep: inventory risk versus PnL volatility.
  {
    const rows = d.gamma_sweep.rows;
    const { c, chart, tbl, lg } = card(grid, { title: "Stronger inventory aversion, calmer PnL", sub: "Largest position held, by risk-aversion gamma", delay: 3 });
    const max = Math.max(...rows.map((r) => r.max_abs_inventory));
    const ticks = niceTicks(0, max, 4);
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 16, right: 24, bottom: 52, left: 48 },
      x: { domain: [0, rows.length], ticks: [] }, y: { domain: [0, ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      yTitle: "largest |inventory|, lots",
    });
    const slot = f.pw / rows.length;
    rows.forEach((r, i) => {
      const cx = slot * i + slot / 2;
      const y1 = f.sy(r.max_abs_inventory);
      roundedBar(f.layer, { x: cx - 12, y0: f.sy(0), y1, w: 24, fill: "var(--seq-3)" });
      const v = el("text", { class: "end-label fade-in", x: cx, y: y1 - 8, "text-anchor": "middle" }, f.layer);
      v.textContent = String(r.max_abs_inventory);
      const l = el("text", { class: "tick", x: cx, y: f.ph + 20, "text-anchor": "middle" }, f.g);
      l.textContent = String(r.gamma);
      const hit = el("rect", { x: cx - slot / 2, y: 0, width: slot, height: f.ph, fill: "transparent", tabindex: 0 }, f.g);
      el("title", {}, hit).textContent = `gamma ${r.gamma}: largest position ${r.max_abs_inventory} lots, PnL step std ${r.pnl_step_std.toFixed(4)}`;
    });
    const lab = el("text", { class: "axis-title", x: f.pw / 2, y: f.ph + 42, "text-anchor": "middle" }, f.g);
    lab.textContent = "risk aversion gamma";
    tableView(tbl, ["Gamma", "Max |inv|", "PnL step std", "Total PnL", "Lots"], rows.map((r) => [r.gamma, r.max_abs_inventory, r.pnl_step_std.toFixed(4), money(r.total_pnl), r.volume]));
    lg.replaceChildren();
    onVisible(c, () => trigger(c));
  }

  // 5. The same strategy across 24 independent seeds: is the edge real?
  {
    const sd = d.seeds;
    const total = sd.components.find((x) => x.name === "total_pnl");
    const rows = [...sd.per_seed_total].sort((a, b) => b.total_pnl - a.total_pnl);
    const { c, chart, tbl, lg } = card(grid, {
      title: `One strategy, ${sd.n_seeds} independent markets`,
      sub: `Total PnL per seed, sorted. Mean ${money(total.mean)}, 95% bootstrap interval ${money(total.ci_lo)} to ${money(total.ci_hi)}`,
      delay: 4,
    });
    const vals = rows.map((r) => r.total_pnl);
    const ticks = niceTicks(Math.min(0, ...vals), Math.max(0, ...vals), 5);
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 16, right: 24, bottom: 40, left: 48 },
      x: { domain: [0, rows.length], ticks: [] }, y: { domain: [ticks[0], ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      yZero: true, xTitle: "seeds, best to worst",
    });
    const slot = f.pw / rows.length;
    rows.forEach((r, i) => {
      const cx = slot * i + slot / 2;
      roundedBar(f.layer, { x: cx - Math.min(10, slot / 2 - 1), y0: f.sy(0), y1: f.sy(r.total_pnl), w: Math.min(20, slot - 2), fill: r.total_pnl >= 0 ? "var(--c1)" : "var(--c2)" });
      const hit = el("rect", { x: cx - slot / 2, y: 0, width: slot, height: f.ph, fill: "transparent", tabindex: 0 }, f.g);
      el("title", {}, hit).textContent = `seed ${r.seed}: ${money(r.total_pnl)}`;
    });
    // the mean and its interval, as a band across the plot
    const band = el("rect", { x: 0, y: f.sy(total.ci_hi), width: f.pw, height: Math.max(2, f.sy(total.ci_lo) - f.sy(total.ci_hi)), fill: "var(--ink)", "fill-opacity": 0.1, class: "fade-in" }, f.layer);
    el("title", {}, band).textContent = `95% interval for the mean: ${money(total.ci_lo)} to ${money(total.ci_hi)}`;
    el("line", { x1: 0, x2: f.pw, y1: f.sy(total.mean), y2: f.sy(total.mean), stroke: "var(--ink)", "stroke-width": 1.5, "stroke-dasharray": "5 5", class: "fade-in" }, f.layer);
    const ml = el("text", { class: "end-label fade-in", x: f.pw - 4, y: f.sy(total.mean) - 8, "text-anchor": "end" }, f.layer);
    ml.textContent = `mean ${money(total.mean)}`;
    tableView(tbl, ["Seed", "Total PnL"], rows.map((r) => [r.seed, money(r.total_pnl)]));
    lg.replaceChildren();
    for (const [name, color] of [["Made money", "var(--c1)"], ["Lost money", "var(--c2)"]]) {
      const b = html("button", { type: "button", "aria-pressed": "true", tabindex: -1, style: "cursor:default" }, lg);
      html("i", { class: "sw", style: `background:${color}` }, b);
      html("span", { text: name }, b);
    }
    const wins = rows.filter((r) => r.total_pnl > 0).length;
    html("span", { class: "sub", style: "margin-left:auto", text: `${wins} of ${rows.length} seeds profitable` }, lg);
    onVisible(c, () => trigger(c));
  }

  const note = document.getElementById("maker-note");
  const sd = d.seeds;
  const tot = sd.components.find((x) => x.name === "total_pnl");
  const comp = (n) => sd.components.find((x) => x.name === n);
  const wins = sd.per_seed_total.filter((r) => r.total_pnl > 0).length;
  const body = html("p", {}, note);
  const lead = html("strong", { text: "What the evidence supports. " }, body);
  lead.style.color = "var(--ink)";
  const excludesZero = tot.ci_lo > 0 || tot.ci_hi < 0;
  html("span", { text: `The single run above ended at ${money(s.total_pnl)}, but across ${sd.n_seeds} independent markets the mean is ${money(tot.mean)} (95% interval ${money(tot.ci_lo)} to ${money(tot.ci_hi)}), and ${wins} of ${sd.n_seeds} seeds made money. ${excludesZero ? "The interval excludes zero, so in this simulator the average is positive, though small next to the spread captured." : "The interval includes zero, so the average is not distinguishable from nothing."} On average spread capture is ${money(comp("spread_capture").mean)}, adverse selection ${money(comp("adverse_selection").mean)} and inventory ${money(comp("inventory").mean)}. There is no latency, fees or queue-position model, and the informed traders and their news are my own assumptions, so read this as a demonstration of the mechanism, not evidence of a tradable edge.` }, body);
  onVisible(note, () => note.classList.add("in"));
}
