// Charts for options, hedging, ETF and risk.

import {
  html, el, frame, niceTicks, fmt, axisFormat, line, roundedBar, roundedBarH, endDot, endLabel,
  crosshair, legend, tableView, wireToggle, onVisible, trigger,
} from "./viz.js";

const money = (v) => (v < 0 ? "-" : "") + Math.abs(v).toFixed(2);
const pct = (v) => (v * 100).toFixed(1) + "%";

function card(parent, { title, sub, delay = 0, wide = false }) {
  const c = html("div", { class: "card reveal", "data-view": "chart", style: `--i:${delay}${wide ? ";grid-column:1/-1" : ""}` }, parent);
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

// ---- volatility surface: four small multiples, one per expiry -----------

export function surfaceSection(d) {
  const grid = document.getElementById("surface-grid");
  // shared y-scale so slices compare honestly
  const allVols = d.surface.slices.flatMap((s) => [...s.quotes.map((q) => q.vol), ...s.fit.map((q) => q.vol)]);
  const yt = niceTicks(Math.min(...allVols) * 0.98, Math.max(...allVols) * 1.02, 5);
  const xs = d.surface.slices.flatMap((s) => s.fit.map((q) => q.strike));
  const xlo = Math.min(...xs);
  const xhi = Math.max(...xs);

  const cal = d.surface.calendar;
  const calNote = html("div", { class: "callout reveal", style: "margin-top:0;margin-bottom:18px;grid-column:1/-1" }, grid);
  html("p", { text: `Across expiries: ${cal.violations === 0 ? "no calendar-spread arbitrage" : cal.violations + " calendar violations"} found. Total variance was compared between each pair of adjacent expiries at ${cal.grid_points} moneyness points${cal.violations === 0 ? "" : " (worst shortfall " + cal.worst_shortfall.toExponential(2) + ")"}. This is a sampled check, not a proof between the sample points.` }, calNote);

  d.surface.slices.forEach((s, i) => {
    const { c, chart, tbl, lg } = card(grid, {
      title: `Expiry ${s.expiry < 1 ? Math.round(s.expiry * 12 * 10) / 10 + " months" : "1 year"}`,
      sub: `SVI fit RMSE ${s.fit_rmse_variance.toExponential(1)} | min butterfly density ${s.min_butterfly_density.toFixed(2)} (positive = no arbitrage)`,
      delay: i,
    });
    const f = frame(chart, {
      width: 520, height: 260, margin: { top: 12, right: 18, bottom: 34, left: 52 },
      x: { domain: [xlo, xhi], ticks: niceTicks(xlo, xhi, 5).filter((t) => t >= xlo && t <= xhi), format: (v) => Math.round(v) },
      y: { domain: [yt[0], yt[yt.length - 1]], ticks: yt, format: (v) => pct(v) },
      xTitle: "strike",
    });
    const fit = s.fit.map((q) => [q.strike, q.vol]);
    line(f.layer, fit, f.sx, f.sy, "var(--c1)");
    s.quotes.forEach((q) => {
      const dot = el("circle", { cx: f.sx(q.strike), cy: f.sy(q.vol), r: 4, fill: "var(--c2)", class: "dot-ring fade-in" }, f.layer);
      el("title", {}, dot).textContent = `strike ${q.strike.toFixed(0)}: implied vol ${pct(q.vol)}`;
    });
    crosshair(f, chart, {
      series: [{ name: "SVI fit", color: "var(--c1)", points: fit }], xs: fit.map((p) => p[0]),
      headFor: (x) => `strike ${x.toFixed(1)}`, valueFor: (_, p) => pct(p[1]),
    });
    tableView(tbl, ["Strike", "Quoted vol"], s.quotes.map((q) => [q.strike.toFixed(0), pct(q.vol)]));
    lg.replaceChildren();
    const mk = (name, color, shape) => {
      const b = html("button", { type: "button", "aria-pressed": "true", tabindex: -1, style: "cursor:default" }, lg);
      const sw = html("i", { class: shape === "dot" ? "sw" : "" }, b);
      sw.style.background = color;
      if (shape === "dot") sw.style.borderRadius = "50%";
      html("span", { text: name }, b);
    };
    mk("SVI fit", "var(--c1)", "line");
    mk("Quoted implied vol", "var(--c2)", "dot");
    onVisible(c, () => trigger(c));
  });
}

// ---- hedging ------------------------------------------------------------

export function hedgeSection(d) {
  const grid = document.getElementById("hedge-grid");
  const h = d.hedging;

  // 1. error vs number of hedges, log-log so the 1/sqrt(n) slope is a straight line
  {
    const { c, chart, tbl, lg } = card(grid, { title: "Hedging error shrinks like 1/sqrt(trades)", sub: "Std of hedged PnL per option, 2,000 paths. Dashed guide = exact 1/sqrt scaling" , delay: 0 });
    const pts = h.scaling.map((r) => [Math.log10(r.steps), Math.log10(r.std_pnl)]);
    const yVals = [0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 3];
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 14, right: 40, bottom: 52, left: 56 },
      x: { domain: [Math.log10(10), Math.log10(700)], ticks: [Math.log10(12), Math.log10(52), Math.log10(252), Math.log10(504)], format: (v) => String(Math.round(10 ** v)) },
      y: { domain: [Math.log10(0.2), Math.log10(3)], ticks: yVals.map((v) => Math.log10(v)), format: (v) => String(+(10 ** v).toPrecision(2)) },
      xTitle: "hedge trades per option (log scale)", yTitle: "std of PnL (log scale)",
    });
    // guide: exact -1/2 slope through the first point
    const [x0, y0] = pts[0];
    const guide = [[Math.log10(10), y0 - 0.5 * (Math.log10(10) - x0)], [Math.log10(700), y0 - 0.5 * (Math.log10(700) - x0)]];
    const g = el("line", { x1: f.sx(guide[0][0]), y1: f.sy(guide[0][1]), x2: f.sx(guide[1][0]), y2: f.sy(guide[1][1]), stroke: "var(--axis)", "stroke-width": 1.5, "stroke-dasharray": "5 5" }, f.layer);
    g.classList.add("fade-in");
    line(f.layer, pts, f.sx, f.sy, "var(--c1)");
    pts.forEach((p, i) => {
      const dot = el("circle", { cx: f.sx(p[0]), cy: f.sy(p[1]), r: 4.5, fill: "var(--c1)", class: "dot-ring fade-in" }, f.layer);
      el("title", {}, dot).textContent = `${h.scaling[i].steps} trades: std ${h.scaling[i].std_pnl.toFixed(3)}, mean ${money(h.scaling[i].mean_pnl)}`;
    });
    tableView(tbl, ["Trades", "Mean PnL", "Std PnL", "Std x sqrt(trades)"], h.scaling.map((r) => [r.steps, money(r.mean_pnl), r.std_pnl.toFixed(3), (r.std_pnl * Math.sqrt(r.steps)).toFixed(2)]));
    lg.replaceChildren();
    const b = html("button", { type: "button", "aria-pressed": "true", tabindex: -1, style: "cursor:default" }, lg);
    const prod = h.scaling.map((r) => r.std_pnl * Math.sqrt(r.steps));
    html("span", { text: `Measured error tracks the 1/sqrt guide: std x sqrt(trades) stays between ${Math.min(...prod).toFixed(1)} and ${Math.max(...prod).toFixed(1)}` }, b);
    onVisible(c, () => trigger(c));
  }

  // 2. profit vs realised vol: bars from a zero baseline (diverging by sign)
  {
    const { c, chart, tbl, lg } = card(grid, { title: "Profit depends on how volatile the stock really is", sub: "Mean hedged PnL when the option was sold at 20% vol, 1,500 paths each", delay: 1 });
    const rows = h.mismatch;
    const vals = rows.map((r) => r.mean_pnl);
    const ticks = niceTicks(Math.min(0, ...vals), Math.max(0, ...vals), 5);
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 16, right: 24, bottom: 44, left: 52 },
      x: { domain: [0, rows.length], ticks: [] }, y: { domain: [ticks[0], ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      yZero: true,
    });
    const slot = f.pw / rows.length;
    rows.forEach((r, i) => {
      const cx = slot * i + slot / 2;
      // sign carries colour: blue = made money, orange = lost money
      roundedBar(f.layer, { x: cx - 12, y0: f.sy(0), y1: f.sy(r.mean_pnl), w: 24, fill: r.mean_pnl >= 0 ? "var(--c1)" : "var(--c2)" });
      const v = el("text", { class: "end-label fade-in", x: cx, y: r.mean_pnl >= 0 ? f.sy(r.mean_pnl) - 8 : f.sy(r.mean_pnl) + 16, "text-anchor": "middle" }, f.layer);
      v.textContent = (r.mean_pnl >= 0 ? "+" : "") + r.mean_pnl.toFixed(2);
      const l = el("text", { class: "tick", x: cx, y: f.ph + 20, "text-anchor": "middle" }, f.g);
      l.textContent = `${Math.round(r.real_vol * 100)}%`;
      const hit = el("rect", { x: cx - slot / 2, y: 0, width: slot, height: f.ph, fill: "transparent", tabindex: 0 }, f.g);
      el("title", {}, hit).textContent = `real vol ${Math.round(r.real_vol * 100)}%: mean ${money(r.mean_pnl)}, std ${r.std_pnl.toFixed(2)}`;
    });
    const lab = el("text", { class: "axis-title", x: f.pw / 2, y: f.ph + 40, "text-anchor": "middle" }, f.g);
    lab.textContent = "realised volatility of the stock";
    tableView(tbl, ["Real vol", "Mean PnL", "Std PnL"], rows.map((r) => [pct(r.real_vol), money(r.mean_pnl), r.std_pnl.toFixed(2)]));
    lg.replaceChildren();
    for (const [name, color] of [["Made money", "var(--c1)"], ["Lost money", "var(--c2)"]]) {
      const b = html("button", { type: "button", "aria-pressed": "true", tabindex: -1, style: "cursor:default" }, lg);
      html("i", { class: "sw", style: `background:${color}` }, b);
      html("span", { text: name }, b);
    }
    onVisible(c, () => trigger(c));
  }

  // 3. one hedged path: stock price on one chart, hedge ratio on another (never dual axis)
  {
    const p = h.example_path;
    const { c, chart, tbl, lg } = card(grid, { title: "One path: the stock", sub: `Real vol 30%. Premium received ${p.premium.toFixed(2)}, final hedged PnL ${money(p.pnl)} (gamma formula predicts ${money(p.pnl_gamma_formula)})`, delay: 2 });
    const pts = p.spots.map((v, i) => [i, v]);
    const ys = pts.map((q) => q[1]);
    const ticks = niceTicks(Math.min(...ys), Math.max(...ys), 5);
    const f = frame(chart, {
      width: 560, height: 260, margin: { top: 14, right: 60, bottom: 34, left: 52 },
      x: { domain: [0, pts.length - 1], ticks: [0, 63, 126, 189, 252], format: (v) => `${(v / 252).toFixed(2)}y` },
      y: { domain: [ticks[0], ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      xTitle: "time to expiry",
    });
    const strikeY = f.sy(100);
    el("line", { x1: 0, x2: f.pw, y1: strikeY, y2: strikeY, stroke: "var(--axis)", "stroke-width": 1.5, "stroke-dasharray": "5 5" }, f.layer);
    const t = el("text", { class: "tick", x: f.pw + 6, y: strikeY + 4 }, f.layer);
    t.textContent = "strike";
    line(f.layer, pts, f.sx, f.sy, "var(--c1)");
    const last = pts[pts.length - 1];
    endDot(f.layer, f.sx(last[0]), f.sy(last[1]), "var(--c1)");
    crosshair(f, chart, {
      series: [{ name: "Stock", color: "var(--c1)", points: pts }], xs: pts.map((q) => q[0]),
      headFor: (x) => `day ${x} of 252`, valueFor: (_, q) => q[1].toFixed(2),
    });
    tableView(tbl, ["Day", "Stock"], pts.filter((_, i) => i % 6 === 0).map((q) => [q[0], q[1].toFixed(2)]));
    lg.replaceChildren();
    onVisible(c, () => trigger(c));
  }
  {
    const p = h.example_path;
    const { c, chart, tbl, lg } = card(grid, { title: "Same path: the hedge ratio", sub: "Shares held per option sold. Moves toward 1 if the option ends in the money, 0 if not", delay: 3 });
    const pts = p.deltas.map((v, i) => [i, v]);
    const f = frame(chart, {
      width: 560, height: 260, margin: { top: 14, right: 60, bottom: 34, left: 52 },
      x: { domain: [0, pts.length - 1], ticks: [0, 63, 126, 189, 251], format: (v) => `${(v / 252).toFixed(2)}y` },
      y: { domain: [0, 1], ticks: [0, 0.25, 0.5, 0.75, 1], format: (v) => v.toFixed(2) },
      xTitle: "time to expiry",
    });
    line(f.layer, pts, f.sx, f.sy, "var(--c3)");
    const last = pts[pts.length - 1];
    endDot(f.layer, f.sx(last[0]), f.sy(last[1]), "var(--c3)");
    endLabel(f.layer, f.sx(last[0]), f.sy(last[1]), last[1].toFixed(2));
    crosshair(f, chart, {
      series: [{ name: "Delta", color: "var(--c3)", points: pts }], xs: pts.map((q) => q[0]),
      headFor: (x) => `day ${x} of 252`, valueFor: (_, q) => q[1].toFixed(3),
    });
    tableView(tbl, ["Day", "Delta"], pts.filter((_, i) => i % 6 === 0).map((q) => [q[0], q[1].toFixed(3)]));
    lg.replaceChildren();
    onVisible(c, () => trigger(c));
  }
}

// ---- ETF ----------------------------------------------------------------

export function etfSection(d) {
  const grid = document.getElementById("etf-grid");
  const e = d.etf;

  // 1. net edge vs ETF premium: the dead zone where costs eat the gap
  {
    const { c, chart, tbl, lg } = card(grid, {
      title: "Net edge by price gap", sub: `NAV ${e.nav.toFixed(2)}. All-in round-trip cost ${e.round_trip_cost.toFixed(3)} per share creates a dead zone either side of NAV`, delay: 0,
    });
    const pts = e.scan.map((r) => [r.gap, r.net_edge]);
    const ys = pts.map((p) => p[1]);
    const ticks = niceTicks(0, Math.max(...ys), 5);
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 14, right: 24, bottom: 40, left: 52 },
      x: { domain: [-1, 1], ticks: [-1, -0.5, 0, 0.5, 1], format: (v) => (v > 0 ? "+" : "") + v.toFixed(1) },
      y: { domain: [0, ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      xTitle: "ETF price minus NAV", yTitle: "net edge per share",
    });
    // dead zone
    const dz = e.round_trip_cost;
    el("rect", { x: f.sx(-dz), y: 0, width: f.sx(dz) - f.sx(-dz), height: f.ph, fill: "var(--hairline)", "fill-opacity": 0.55, class: "fade-in" }, f.layer);
    const lbl = el("text", { class: "tick", x: f.sx(0), y: 16, "text-anchor": "middle" }, f.layer);
    lbl.textContent = "no trade";
    const buy = pts.filter((p) => p[0] < 0);
    const sell = pts.filter((p) => p[0] > 0);
    line(f.layer, buy, f.sx, f.sy, "var(--c1)");
    line(f.layer, sell, f.sx, f.sy, "var(--c2)");
    crosshair(f, chart, {
      series: [{ name: "Net edge", color: "var(--c1)", points: pts }], xs: pts.map((p) => p[0]),
      headFor: (x) => `ETF ${(x >= 0 ? "+" : "") + x.toFixed(2)} vs NAV`,
      valueFor: (_, p) => (p[1] > 0 ? p[1].toFixed(3) + " per share" : "no trade"),
    });
    tableView(tbl, ["Gap", "Net edge", "Action"], e.scan.map((r) => [r.gap.toFixed(2), r.net_edge.toFixed(3), r.direction.replaceAll("_", " ")]));
    lg.replaceChildren();
    for (const [name, color] of [["Buy ETF, sell basket (discount)", "var(--c1)"], ["Sell ETF, buy basket (premium)", "var(--c2)"]]) {
      const b = html("button", { type: "button", "aria-pressed": "true", tabindex: -1, style: "cursor:default" }, lg);
      html("i", { style: `background:${color}` }, b);
      html("span", { text: name }, b);
    }
    onVisible(c, () => trigger(c));
  }

  // 2. hedge quality: residual risk with 2 of 3 names vs all 3, vs unhedged (single hue ranked bars)
  {
    const two = e.hedge_two_of_three;
    const three = e.hedge_all_three;
    const { c, chart, tbl, lg } = card(grid, { title: "Hedging an ETF without every stock", sub: "Daily return std, in basis points, after hedging", delay: 1 });
    const rows = [
      { name: "Unhedged", v: two.unhedged_std * 1e4 },
      { name: "Hedge with 2 of 3 stocks", v: two.residual_std * 1e4, r2: two.r_squared },
      { name: "Hedge with all 3 stocks", v: three.residual_std * 1e4, r2: three.r_squared },
    ];
    const max = Math.max(...rows.map((r) => r.v));
    const f = frame(chart, {
      width: 560, height: 240, margin: { top: 10, right: 110, bottom: 52, left: 160 },
      x: { domain: [0, niceTicks(0, max, 4).at(-1)], ticks: niceTicks(0, max, 4), format: axisFormat(niceTicks(0, max, 4)) },
      y: { domain: [0, 1], ticks: [] },
      xTitle: "basis points of daily return",
    });
    const bh = 24;
    const slot = f.ph / rows.length;
    rows.forEach((r, i) => {
      const cy = slot * i + slot / 2;
      const x1 = f.sx(r.v);
      roundedBarH(f.layer, { x0: 0, x1: Math.max(x1, 2), y: cy - bh / 2, h: bh, fill: "var(--seq-3)" });
      const nm = el("text", { class: "tick", x: -10, y: cy + 4, "text-anchor": "end", style: "fill:var(--ink-2);font-size:12.5px" }, f.g);
      nm.textContent = r.name;
      const v = el("text", { class: "end-label fade-in", x: Math.max(x1, 2) + 8, y: cy + 4 }, f.layer);
      v.textContent = r.v < 0.01 ? "~0" : r.v.toFixed(1) + (r.r2 != null ? `  (R² ${r.r2.toFixed(3)})` : "");
      const hit = el("rect", { x: 0, y: cy - slot / 2, width: f.pw, height: slot, fill: "transparent", tabindex: 0 }, f.g);
      el("title", {}, hit).textContent = `${r.name}: ${r.v.toFixed(2)} bp`;
    });
    tableView(tbl, ["Hedge", "Residual std (bp)", "R squared"], [
      ["Unhedged", (two.unhedged_std * 1e4).toFixed(2), "-"],
      ["2 of 3 stocks", (two.residual_std * 1e4).toFixed(2), two.r_squared.toFixed(4)],
      ["All 3 stocks", (three.residual_std * 1e4).toFixed(4), three.r_squared.toFixed(4)],
    ]);
    lg.replaceChildren();
    onVisible(c, () => trigger(c));
  }
}

// ---- ETF market: the basket wired to a real order book -------------------

export function etfMarketSection(d) {
  const grid = document.getElementById("etf-grid");
  const m = d.etf_market;

  // 1. PnL decomposition by how much weight the maker puts on the basket NAV
  {
    const rows = m.by_nav_weight;
    const { c, chart, tbl, lg } = card(grid, {
      title: "Quoting around the basket, not the ETF's own price",
      sub: `ETF market maker, mean of ${m.seeds} seeds. Weight 0 quotes around the book's mid; weight 1 quotes around the basket NAV`,
      delay: 2,
    });
    const parts = [
      { key: "spread_capture", name: "Spread capture", color: "var(--c1)" },
      { key: "adverse_selection", name: "Adverse selection", color: "var(--c2)" },
      { key: "inventory", name: "Inventory", color: "var(--c3)" },
    ];
    const vals = rows.flatMap((r) => parts.map((p) => r[p.key]));
    const ticks = niceTicks(Math.min(0, ...vals), Math.max(0, ...vals), 5);
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 14, right: 24, bottom: 52, left: 48 },
      x: { domain: [0, rows.length], ticks: [] },
      y: { domain: [ticks[0], ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      yZero: true, yTitle: "currency units",
    });
    const slot = f.pw / rows.length;
    const bw = 14;
    const gap = 2;
    rows.forEach((r, i) => {
      const cx = slot * i + slot / 2;
      parts.forEach((p, k) => {
        const x = cx - (bw * 3 + gap * 2) / 2 + k * (bw + gap);
        roundedBar(f.layer, { x, y0: f.sy(0), y1: f.sy(r[p.key]), w: bw, fill: p.color, r: 3 });
      });
      const l = el("text", { class: "tick", x: cx, y: f.ph + 22, "text-anchor": "middle" }, f.g);
      l.textContent = r.nav_weight.toFixed(2);
      const hit = el("rect", { x: cx - slot / 2, y: 0, width: slot, height: f.ph, fill: "transparent", tabindex: 0 }, f.g);
      el("title", {}, hit).textContent = `NAV weight ${r.nav_weight}: total ${money(r.total_pnl)} = spread ${money(r.spread_capture)} + adverse ${money(r.adverse_selection)} + inventory ${money(r.inventory)}`;
    });
    const lab = el("text", { class: "axis-title", x: f.pw / 2, y: f.ph + 42, "text-anchor": "middle" }, f.g);
    lab.textContent = "weight on the basket NAV";
    tableView(tbl, ["NAV weight", "Total", "Spread", "Adverse", "Inventory", "Max |inv|"], rows.map((r) => [r.nav_weight.toFixed(2), money(r.total_pnl), money(r.spread_capture), money(r.adverse_selection), money(r.inventory), r.max_abs_inventory.toFixed(1)]));
    lg.replaceChildren();
    for (const p of parts) {
      const b = html("button", { type: "button", "aria-pressed": "true", tabindex: -1, style: "cursor:default" }, lg);
      html("i", { class: "sw", style: `background:${p.color}` }, b);
      html("span", { text: p.name }, b);
    }
    onVisible(c, () => trigger(c));
  }

  // 2. How much of the gain survives when the book follows the basket closely?
  {
    const rows = m.by_book_lag;
    const { c, chart, tbl, lg } = card(grid, {
      title: "How much of the gain is protection, and how much is foresight?",
      sub: "Gain of a half-NAV maker over the own-mid maker, split into its parts, as the ETF book follows the basket more slowly",
      delay: 3,
    });
    const series = [
      { name: "Adverse selection", color: "var(--c2)", key: "adverse_gain" },
      { name: "Inventory", color: "var(--c3)", key: "inventory_gain" },
    ];
    const lx = rows.map((r) => Math.log10(r.lag_events));
    const vals = rows.flatMap((r) => series.map((s2) => r[s2.key]));
    const ticks = niceTicks(0, Math.max(...vals), 5);
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 14, right: 110, bottom: 52, left: 52 },
      x: { domain: [Math.min(...lx), Math.max(...lx)], ticks: lx, format: (v) => String(Math.round(10 ** v)) },
      y: { domain: [0, ticks[ticks.length - 1]], ticks, format: axisFormat(ticks) },
      xTitle: "events for the ETF book to catch up with the basket (log scale)", yTitle: "gain, currency units",
    });
    series.forEach((s2) => {
      const pts = rows.map((r) => [Math.log10(r.lag_events), r[s2.key]]);
      line(f.layer, pts, f.sx, f.sy, s2.color);
      pts.forEach((p, i) => {
        const dot = el("circle", { cx: f.sx(p[0]), cy: f.sy(p[1]), r: 4, fill: s2.color, class: "dot-ring fade-in" }, f.layer);
        el("title", {}, dot).textContent = `lag ${rows[i].lag_events}: ${s2.name} gain ${money(p[1])}`;
      });
      const last = pts[pts.length - 1];
      endLabel(f.layer, f.sx(last[0]), f.sy(last[1]), s2.name.split(" ")[0]);
    });
    tableView(tbl, ["Lag (events)", "Total gain", "Adverse gain", "Inventory gain"], rows.map((r) => [r.lag_events, money(r.total_gain), money(r.adverse_gain), money(r.inventory_gain)]));
    lg.replaceChildren();
    for (const s2 of series) {
      const b = html("button", { type: "button", "aria-pressed": "true", tabindex: -1, style: "cursor:default" }, lg);
      html("i", { style: `background:${s2.color}` }, b);
      html("span", { text: s2.name }, b);
    }
    onVisible(c, () => trigger(c));
  }

  const first = m.by_book_lag[0];
  const last = m.by_book_lag[m.by_book_lag.length - 1];
  const note = html("div", { class: "callout reveal", style: "grid-column:1/-1;margin-top:0" }, grid);
  const body = html("p", {}, note);
  html("strong", { text: "Read this carefully. ", style: "color:var(--ink)" }, body);
  html("span", { text: `The gain splits into two measured parts. The adverse-selection part, the mid-price move over the next 100 events against each fill, improves most when the ETF book follows the basket closely (${money(first.adverse_gain)} at a ${first.lag_events}-event lag, against ${money(last.adverse_gain)} at ${last.lag_events}). The rest, the inventory part, grows as the book lags (${money(first.inventory_gain)} to ${money(last.inventory_gain)}) and is a forecasting edge: the basket leads the book, so a maker that watches it holds the side the price is moving toward. In this simulation the book follows the basket with a delay by construction, so that edge is an assumption of the model, not a finding about real markets.` }, body);
}

// ---- risk ---------------------------------------------------------------

export function riskSection(d) {
  const grid = document.getElementById("risk-grid");
  const r = d.risk;

  // 1. histogram, single hue
  {
    const { c, chart, tbl, lg } = card(grid, { title: "Distribution of hedged PnL", sub: `${r.paths.toLocaleString()} paths, mean ${money(r.mean)}, std ${r.std.toFixed(2)}. Marks show 99% VaR and ES`, delay: 0 });
    const counts = r.histogram.counts;
    const lo = r.histogram.lo;
    const w = r.histogram.width;
    const maxC = Math.max(...counts);
    const ticks = niceTicks(0, maxC, 4);
    const f = frame(chart, {
      width: 560, height: 300, margin: { top: 14, right: 24, bottom: 40, left: 52 },
      x: { domain: [lo, lo + w * counts.length], ticks: niceTicks(lo, lo + w * counts.length, 6).filter((t) => t >= lo && t <= lo + w * counts.length), format: axisFormat(niceTicks(lo, lo + w * counts.length, 6)) },
      y: { domain: [0, ticks.at(-1)], ticks, format: axisFormat(ticks) },
      xTitle: "hedged PnL per option", yTitle: "paths",
    });
    const bw = Math.max(2, f.sx(lo + w) - f.sx(lo) - 2);
    counts.forEach((n, i) => {
      if (!n) return;
      const x = f.sx(lo + w * i) + 1;
      roundedBar(f.layer, { x, y0: f.sy(0), y1: f.sy(n), w: bw, fill: "var(--seq-3)", r: 3 });
      const hit = el("rect", { x, y: 0, width: bw, height: f.ph, fill: "transparent", tabindex: 0 }, f.g);
      el("title", {}, hit).textContent = `${money(lo + w * i)} to ${money(lo + w * (i + 1))}: ${n} paths`;
    });
    const l99 = r.levels.find((l) => l.confidence === 0.99);
    for (const [name, v, color] of [["VaR 99%", -l99.var, "var(--c2)"], ["ES 99%", -l99.es, "var(--c3)"]]) {
      const x = f.sx(v);
      el("line", { x1: x, x2: x, y1: 0, y2: f.ph, stroke: color, "stroke-width": 2, class: "fade-in" }, f.layer);
      const t = el("text", { class: "end-label fade-in", x, y: name.startsWith("ES") ? 14 : 30, "text-anchor": name.startsWith("ES") ? "end" : "start", dx: name.startsWith("ES") ? -6 : 6 }, f.layer);
      t.textContent = `${name} ${money(-v)}`;
    }
    tableView(tbl, ["Bin start", "Bin end", "Paths"], counts.map((n, i) => [money(lo + w * i), money(lo + w * (i + 1)), n]));
    lg.replaceChildren();
    onVisible(c, () => trigger(c));
  }

  // 2. VaR / ES table with the normal comparison
  {
    const { c, chart, tbl, lg } = card(grid, { title: "Historical versus normal estimates", sub: "Loss at each confidence level; positive numbers are losses", delay: 1 });
    chart.replaceChildren();
    const t = html("table", { class: "data", style: "margin-top:2px" }, chart);
    const hd = html("thead", {}, t);
    const hr = html("tr", {}, hd);
    ["Confidence", "VaR", "Normal VaR", "ES", "Normal ES"].forEach((x) => html("th", { text: x }, hr));
    const tb = html("tbody", {}, t);
    r.levels.forEach((l) => {
      const row = html("tr", {}, tb);
      [pct(l.confidence), l.var.toFixed(2), l.normal_var.toFixed(2), l.es.toFixed(2), l.normal_es.toFixed(2)].forEach((x) => html("td", { text: x }, row));
    });
    const note = html("p", { class: "sub", style: "margin-top:14px;line-height:1.6" }, chart);
    const l99 = r.levels.find((l) => l.confidence === 0.99);
    note.textContent = `Expected shortfall is never smaller than VaR. At 99% the historical VaR is ${l99.var.toFixed(2)} against ${l99.normal_var.toFixed(2)} from a normal fit, so a bell curve would understate this loss by ${((1 - l99.normal_var / l99.var) * 100).toFixed(0)}%. The histogram is visibly skewed, which a normal fit cannot capture.`;
    c.querySelector(".view-toggle").remove();
    lg.remove();
    onVisible(c, () => {});
  }
}

// ---- stack section ------------------------------------------------------

export function stackSection(d) {
  const host = document.getElementById("stack-list");
  const items = [
    ["Order book", "Persistent price-time priority book. Abstract Price and Qty types make negative sizes and mixed units unrepresentable.", "lib/book"],
    ["Simulator", "Seeded, event-driven flow with a hidden fundamental, informed traders and per-order lifetimes. Same seed, same bytes.", "lib/sim"],
    ["Market maker", "Avellaneda-Stoikov quotes, post-only, with inventory limits. PnL split into three parts that sum exactly.", "lib/mm"],
    ["Options", "Black-Scholes and Greeks, safeguarded implied vol, SVI fit with a butterfly-arbitrage check, delta hedging.", "lib/options"],
    ["ETF", "NAV and creation/redemption signal with all-in costs, and a least-squares partial-basket hedge.", "lib/etf"],
    ["Risk", "Historical and normal value-at-risk and expected shortfall.", "lib/risk"],
    ["Tests", "Expect tests, randomised property tests and statistical tests. Each one was mutation-checked to confirm it can fail.", "dune runtest"],
    ["This page", "Plain HTML, CSS and ES modules. No framework, no build step. Data comes from `quoteline export`.", "web/"],
  ];
  items.forEach(([h, p, code], i) => {
    const s = html("div", { class: "stack-item reveal", style: `--i:${i}` }, host);
    html("h3", { text: h }, s);
    html("p", { text: p }, s);
    const cd = html("p", {}, s);
    html("code", { text: code, style: "color:var(--ink-3)" }, cd);
  });
  document.getElementById("foot-meta").textContent = `seed ${d.backtest.seed} | ${d.backtest.events.toLocaleString()} events`;
}
