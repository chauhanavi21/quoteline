// Small SVG charting kit. No dependencies. Every chart in the page is built
// from these pieces so the mark specs stay identical everywhere:
//   lines 2px round, bars <= 24px with a 4px rounded data end, hairline solid
//   grids, a 2px surface ring on dots, text in text tokens (never series colour).

const NS = "http://www.w3.org/2000/svg";

export function el(tag, attrs = {}, parent) {
  const n = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
  if (parent) parent.appendChild(n);
  return n;
}

export function html(tag, props = {}, parent) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "text") n.textContent = v; // untrusted strings: textContent only
    else if (k === "class") n.className = v;
    else n.setAttribute(k, v);
  }
  if (parent) parent.appendChild(n);
  return n;
}

// ---- scales and ticks ---------------------------------------------------

export function linear(d0, d1, r0, r1) {
  const f = (x) => r0 + ((x - d0) / (d1 - d0 || 1)) * (r1 - r0);
  f.invert = (y) => d0 + ((y - r0) / (r1 - r0 || 1)) * (d1 - d0);
  f.domain = [d0, d1];
  return f;
}

// "Nice" tick values covering [lo, hi].
export function niceTicks(lo, hi, count = 5) {
  if (lo === hi) {
    lo -= 1;
    hi += 1;
  }
  const span = hi - lo;
  const raw = span / Math.max(1, count);
  const mag = 10 ** Math.floor(Math.log10(raw));
  const norm = raw / mag;
  const step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag;
  const start = Math.floor(lo / step) * step;
  const end = Math.ceil(hi / step) * step;
  const ticks = [];
  for (let v = start; v <= end + step * 1e-9; v += step) ticks.push(+v.toFixed(10));
  return ticks;
}

export function fmt(v, digits) {
  if (v == null || Number.isNaN(v)) return "n/a";
  const a = Math.abs(v);
  if (digits != null) return v.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
  if (a >= 1e6) return (v / 1e6).toFixed(1) + "M";
  if (a >= 1e4) return (v / 1e3).toFixed(1) + "K";
  if (a === 0) return "0";
  if (Number.isInteger(v)) return v.toLocaleString("en-US");
  if (a >= 100) return v.toLocaleString("en-US", { maximumFractionDigits: 0 });
  if (a >= 10) return v.toFixed(1);
  if (a >= 1) return v.toFixed(2);
  return v.toFixed(3);
}

// Format every tick of one axis with the same number of decimals, so an axis
// never mixes "50.0" with "100".
export function axisFormat(ticks) {
  const step = ticks.length > 1 ? Math.abs(ticks[1] - ticks[0]) : 1;
  const decimals = step >= 1 ? 0 : Math.min(4, Math.ceil(-Math.log10(step) - 1e-9));
  return (v) => v.toLocaleString("en-US", { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
}

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
export const color = (slot) => `var(${slot})`;

// ---- chart frame --------------------------------------------------------

// Creates the svg, plot area, grid and axes. Returns helpers to draw into it.
export function frame(host, opts) {
  const {
    width = 640,
    height = 300,
    margin = { top: 14, right: 64, bottom: 34, left: 52 },
    x, // { domain:[a,b], ticks:[...], format }
    y,
    xTitle,
    yTitle,
    yZero = false, // draw a stronger baseline at y = 0
  } = opts;

  host.querySelector("svg")?.remove();
  const svg = el("svg", { viewBox: `0 0 ${width} ${height}`, role: "img" });
  host.prepend(svg);
  const pw = width - margin.left - margin.right;
  const ph = height - margin.top - margin.bottom;
  const sx = linear(x.domain[0], x.domain[1], 0, pw);
  const sy = linear(y.domain[0], y.domain[1], ph, 0);
  const g = el("g", { transform: `translate(${margin.left},${margin.top})` }, svg);

  const grid = el("g", {}, g);
  for (const t of y.ticks) {
    const yy = sy(t);
    el("line", { class: "grid-line", x1: 0, x2: pw, y1: yy, y2: yy }, grid);
    const tx = el("text", { class: "tick", x: -10, y: yy + 4, "text-anchor": "end" }, grid);
    tx.textContent = (y.format ?? fmt)(t);
  }
  if (yZero && y.domain[0] < 0 && y.domain[1] > 0) {
    el("line", { class: "axis-line", x1: 0, x2: pw, y1: sy(0), y2: sy(0) }, g);
  }
  for (const t of x.ticks) {
    const xx = sx(t);
    const tx = el("text", { class: "tick", x: xx, y: ph + 22, "text-anchor": "middle" }, g);
    tx.textContent = (x.format ?? fmt)(t);
  }
  el("line", { class: "axis-line", x1: 0, x2: pw, y1: ph, y2: ph }, g);
  if (xTitle) {
    // below the tick row (ticks sit at ph + 22), inside the bottom margin
    const t = el("text", { class: "axis-title", x: pw / 2, y: ph + 40, "text-anchor": "middle" }, g);
    t.textContent = xTitle;
  }
  if (yTitle) {
    const t = el("text", { class: "axis-title", x: -ph / 2, y: -margin.left + 12, "text-anchor": "middle", transform: "rotate(-90)" }, g);
    t.textContent = yTitle;
  }

  const layer = el("g", {}, g);
  return { svg, g, layer, sx, sy, pw, ph, margin, width, height };
}

// ---- marks --------------------------------------------------------------

export function pathD(points, sx, sy) {
  let d = "";
  points.forEach((p, i) => {
    const x = sx(p[0]);
    const y = sy(p[1]);
    if (!Number.isFinite(y)) return;
    d += (d ? "L" : "M") + x.toFixed(2) + " " + y.toFixed(2);
  });
  return d;
}

// A 2px line that draws itself in on entry.
export function line(parent, points, sx, sy, stroke, extra = {}) {
  const p = el("path", { class: "line draw", d: pathD(points, sx, sy), stroke, ...extra }, parent);
  p.style.setProperty("--len", Math.ceil(p.getTotalLength?.() ?? 2000) + 2);
  return p;
}

// Area wash at ~10% of the series colour (never a saturated block).
export function area(parent, points, sx, sy, fill, baseY) {
  const top = pathD(points, sx, sy);
  if (!top) return null;
  const first = points[0];
  const last = points[points.length - 1];
  const d = `${top}L${sx(last[0]).toFixed(2)} ${baseY}L${sx(first[0]).toFixed(2)} ${baseY}Z`;
  return el("path", { class: "area fade-in", d, fill, "fill-opacity": 0.1 }, parent);
}

// Vertical bar: 4px rounded data end, square at the baseline. Returns the rect.
export function roundedBar(parent, { x, y0, y1, w, fill, r = 4 }) {
  const top = Math.min(y0, y1);
  const h = Math.abs(y1 - y0);
  const rr = Math.min(r, w / 2, h);
  const up = y1 < y0; // data end is the top for positive bars
  let d;
  if (up) {
    d = `M${x} ${y0}V${top + rr}Q${x} ${top} ${x + rr} ${top}H${x + w - rr}Q${x + w} ${top} ${x + w} ${top + rr}V${y0}Z`;
  } else {
    const bot = top + h;
    d = `M${x} ${y0}V${bot - rr}Q${x} ${bot} ${x + rr} ${bot}H${x + w - rr}Q${x + w} ${bot} ${x + w} ${bot - rr}V${y0}Z`;
  }
  return el("path", { d, fill, class: "grow" }, parent);
}

// Horizontal bar growing from x0 with a rounded data end.
export function roundedBarH(parent, { x0, x1, y, h, fill, r = 4 }) {
  const left = Math.min(x0, x1);
  const w = Math.abs(x1 - x0);
  const rr = Math.min(r, h / 2, w);
  const right = x1 > x0;
  let d;
  if (right) {
    d = `M${x0} ${y}H${left + w - rr}Q${left + w} ${y} ${left + w} ${y + rr}V${y + h - rr}Q${left + w} ${y + h} ${left + w - rr} ${y + h}H${x0}Z`;
  } else {
    d = `M${x0} ${y}H${left + rr}Q${left} ${y} ${left} ${y + rr}V${y + h - rr}Q${left} ${y + h} ${left + rr} ${y + h}H${x0}Z`;
  }
  return el("path", { d, fill, class: "grow h" }, parent);
}

export function endDot(parent, cx, cy, fill) {
  return el("circle", { cx, cy, r: 4.5, fill, class: "dot-ring fade-in" }, parent);
}

export function endLabel(parent, x, y, text) {
  const t = el("text", { class: "end-label fade-in", x: x + 10, y: y + 4 }, parent);
  t.textContent = text;
  return t;
}

// ---- tooltip ------------------------------------------------------------

export function makeTip(host) {
  const tip = html("div", { class: "tip", role: "status" }, host);
  return {
    show(clientX, clientY, head, rows) {
      tip.replaceChildren();
      html("div", { class: "t-head", text: head }, tip);
      for (const r of rows) {
        const row = html("div", { class: "t-row" }, tip);
        const key = html("span", { class: "t-key" }, row);
        key.style.background = r.color;
        html("span", { class: "t-name", text: r.name }, row);
        html("span", { class: "t-val", text: r.value }, row);
      }
      const hb = host.getBoundingClientRect();
      const tb = tip.getBoundingClientRect();
      let left = clientX - hb.left + 16;
      if (left + tb.width > hb.width) left = clientX - hb.left - tb.width - 16;
      let top = clientY - hb.top - tb.height / 2;
      top = Math.max(0, Math.min(hb.height - tb.height, top));
      tip.style.left = `${Math.max(0, left)}px`;
      tip.style.top = `${top}px`;
      tip.classList.add("on");
    },
    hide() {
      tip.classList.remove("on");
    },
  };
}

// Crosshair that snaps to the nearest x, one tooltip listing every series.
// `series`: [{ name, color, points:[[x,y],...] }], `xs` sorted unique x values.
export function crosshair(chart, host, { series, xs, headFor, valueFor }) {
  const tip = makeTip(host);
  const { g, sx, sy, pw, ph, svg } = chart;
  const cross = el("line", { class: "cross", y1: 0, y2: ph, opacity: 0 }, g);
  const dots = series.map((s) => el("circle", { r: 4.5, fill: s.color, class: "dot-ring", opacity: 0 }, g));
  const overlay = el("rect", { x: 0, y: 0, width: pw, height: ph, fill: "transparent", style: "cursor:crosshair", tabindex: 0, "aria-label": "Chart readout. Use left and right arrow keys." }, g);

  let idx = 0;
  const nearest = (xv) => {
    let lo = 0;
    let hi = xs.length - 1;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (xs[mid] < xv) lo = mid;
      else hi = mid;
    }
    return Math.abs(xs[lo] - xv) <= Math.abs(xs[hi] - xv) ? lo : hi;
  };
  const draw = (i, cx, cy) => {
    idx = i;
    const xv = xs[i];
    cross.setAttribute("x1", sx(xv));
    cross.setAttribute("x2", sx(xv));
    cross.setAttribute("opacity", 1);
    const rows = [];
    series.forEach((s, k) => {
      if (s.hidden) {
        dots[k].setAttribute("opacity", 0);
        return;
      }
      const p = s.points.find((q) => q[0] === xv);
      if (!p) {
        dots[k].setAttribute("opacity", 0);
        return;
      }
      dots[k].setAttribute("cx", sx(p[0]));
      dots[k].setAttribute("cy", sy(p[1]));
      dots[k].setAttribute("opacity", 1);
      rows.push({ name: s.name, color: s.color, value: valueFor(s, p) });
    });
    const sb = svg.getBoundingClientRect();
    const px = cx ?? sb.left + (chart.margin.left + sx(xv)) * (sb.width / chart.width);
    const py = cy ?? sb.top + sb.height / 2;
    tip.show(px, py, headFor(xv), rows);
  };
  const hide = () => {
    cross.setAttribute("opacity", 0);
    dots.forEach((d) => d.setAttribute("opacity", 0));
    tip.hide();
  };
  overlay.addEventListener("pointermove", (e) => {
    const b = svg.getBoundingClientRect();
    const scale = chart.width / b.width;
    const xv = sx.invert((e.clientX - b.left) * scale - chart.margin.left);
    draw(nearest(xv), e.clientX, e.clientY);
  });
  overlay.addEventListener("pointerleave", hide);
  overlay.addEventListener("blur", hide);
  overlay.addEventListener("focus", () => draw(idx));
  overlay.addEventListener("keydown", (e) => {
    if (e.key === "ArrowRight") draw(Math.min(xs.length - 1, idx + 1)), e.preventDefault();
    if (e.key === "ArrowLeft") draw(Math.max(0, idx - 1)), e.preventDefault();
    if (e.key === "Escape") hide();
  });
  return { hide };
}

// ---- legend + table twin ------------------------------------------------

// Legend with toggle-to-isolate. `onChange(hiddenSet)` re-renders the chart.
export function legend(host, items, onChange, kind = "line") {
  host.replaceChildren();
  const hidden = new Set();
  for (const it of items) {
    const b = html("button", { type: "button", "aria-pressed": "true" }, host);
    const sw = html("i", { class: kind === "line" ? "" : "sw" }, b);
    sw.style.background = it.color;
    html("span", { text: it.name }, b);
    b.addEventListener("click", () => {
      if (hidden.has(it.name)) hidden.delete(it.name);
      else hidden.add(it.name);
      // never allow every series to be hidden
      if (hidden.size === items.length) hidden.clear();
      host.querySelectorAll("button").forEach((x, i) => x.setAttribute("aria-pressed", String(!hidden.has(items[i].name))));
      onChange(hidden);
    });
  }
  return hidden;
}

// Table-view twin: header strings + rows of already-formatted cells.
export function tableView(host, headers, rows) {
  host.replaceChildren();
  const t = html("table", { class: "data" }, host);
  const thead = html("thead", {}, t);
  const hr = html("tr", {}, thead);
  headers.forEach((h) => html("th", { text: h }, hr));
  const tb = html("tbody", {}, t);
  rows.forEach((r) => {
    const tr = html("tr", {}, tb);
    r.forEach((c) => html("td", { text: String(c) }, tr));
  });
}

// Wire a card's "Table" toggle. Cards carry data-view="chart" | "table".
export function wireToggle(card) {
  const btn = card.querySelector(".view-toggle");
  if (!btn) return;
  btn.addEventListener("click", () => {
    const next = card.dataset.view === "table" ? "chart" : "table";
    card.dataset.view = next;
    btn.textContent = next === "table" ? "Chart view" : "Table view";
    btn.setAttribute("aria-pressed", String(next === "table"));
  });
}

// ---- motion helpers -----------------------------------------------------

export const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

// Run `fn` once when `node` first scrolls into view.
export function onVisible(node, fn, threshold = 0.25) {
  if (reduced()) {
    fn();
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          io.disconnect();
          fn();
        }
      }
    },
    { threshold },
  );
  io.observe(node);
}

export function trigger(root) {
  root.querySelectorAll(".draw, .fade-in, .grow").forEach((n, i) => {
    n.style.setProperty("--i", i % 40);
    n.classList.add("go");
  });
}

// Animate a number from 0 to `to` over ~900ms.
export function countUp(node, to, format) {
  if (reduced() || !Number.isFinite(to)) {
    node.textContent = format(to);
    return;
  }
  const t0 = performance.now();
  const dur = 1100;
  const tick = (t) => {
    const p = Math.min(1, (t - t0) / dur);
    const e = 1 - (1 - p) ** 4;
    node.textContent = format(to * e);
    if (p < 1) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
