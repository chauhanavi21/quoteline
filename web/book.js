// Order-book replay: steps through real engine events, drawing depth bars,
// the spread and a trade tape. Scrubbing jumps straight to any event.

import { html, reduced, onVisible } from "./viz.js";

const px = (v) => v.toFixed(2);

export function initBook(data) {
  const events = data.events;
  const ladder = document.getElementById("ladder");
  const tape = document.getElementById("tape");
  const scrub = document.getElementById("scrub");
  const playBtn = document.getElementById("play");
  const speedBox = document.getElementById("speed");
  const spreadPill = document.getElementById("spread-pill");
  const counter = document.getElementById("event-count");
  const depth = data.depth;

  // Build the ladder rows once; later updates only change text and widths.
  ladder.replaceChildren();
  const head = html("div", { class: "head" }, ladder);
  html("span", { text: "Bid size" }, head);
  html("span", { text: "Bid | Ask" }, head);
  html("span", { text: "Ask size" }, head);
  const rows = [];
  for (let i = 0; i < depth; i++) {
    const row = html("div", { class: "row" }, ladder);
    const bd = html("div", { class: "depth bid" }, row);
    const bb = html("div", { class: "bar" }, bd);
    const bq = html("span", { class: "qty" }, bd);
    const prices = html("div", { class: "prices" }, row);
    const bp = html("span", {}, prices);
    const ap = html("span", {}, prices);
    const ad = html("div", { class: "depth ask" }, row);
    const ab = html("div", { class: "bar" }, ad);
    const aq = html("span", { class: "qty" }, ad);
    rows.push({ b: bd, a: ad, bb, ab, bq, bp, ap, aq });
  }

  const maxQty = Math.max(1, ...events.flatMap((e) => [...e.bids, ...e.asks].map((l) => l.qty)));
  let idx = 0;
  let playing = true;
  let speed = 2;
  let timer = null;
  let lastTape = -1;

  function flash(node) {
    if (reduced()) return;
    node.classList.remove("flash");
    void node.offsetWidth; // restart the animation
    node.classList.add("flash");
  }

  function render(i, { animate = true } = {}) {
    const e = events[i];
    const prev = i > 0 ? events[i - 1] : null;
    for (let k = 0; k < depth; k++) {
      const r = rows[k];
      const bid = e.bids[k];
      const ask = e.asks[k];
      r.bq.textContent = bid ? String(bid.qty) : "";
      r.bp.textContent = bid ? px(bid.price) : "";
      r.ap.textContent = ask ? px(ask.price) : "";
      r.aq.textContent = ask ? String(ask.qty) : "";
      r.bb.style.width = bid ? `${Math.max(3, (bid.qty / maxQty) * 100)}%` : "0%";
      r.ab.style.width = ask ? `${Math.max(3, (ask.qty / maxQty) * 100)}%` : "0%";
      if (animate && prev) {
        const pb = prev.bids[k];
        const pa = prev.asks[k];
        if (bid && (!pb || pb.price !== bid.price || pb.qty !== bid.qty)) flash(r.b);
        if (ask && (!pa || pa.price !== ask.price || pa.qty !== ask.qty)) flash(r.a);
      }
    }
    const bb = e.bids[0];
    const ba = e.asks[0];
    spreadPill.textContent = bb && ba ? `spread ${px(ba.price - bb.price)}  |  mid ${px((ba.price + bb.price) / 2)}` : "one-sided book";
    counter.textContent = `event ${i + 1} of ${events.length}  |  ${e.kind}${e.side ? " " + e.side.toLowerCase() : ""}`;
    scrub.value = i;
  }

  function pushTrades(i) {
    const e = events[i];
    if (!e.trades.length) return;
    tape.querySelector(".empty")?.remove();
    for (const t of e.trades) {
      const li = html("li", {}, tape);
      html("span", { class: t.taker_side === "BUY" ? "buy" : "sell", text: t.taker_side === "BUY" ? "BUY " : "SELL" }, li);
      html("span", { text: `${t.qty} @ ${px(t.price)}` }, li);
      html("span", { text: `${(e.t_us / 1e6).toFixed(3)}s`, style: "margin-left:auto;color:var(--ink-3)" }, li);
      tape.prepend(li);
    }
    while (tape.children.length > 14) tape.lastChild.remove();
  }

  function resetTape() {
    tape.replaceChildren();
    html("li", { class: "empty", text: "Waiting for the first trade..." }, tape);
  }

  function seek(i) {
    // Rebuild the tape from scratch up to i so scrubbing is consistent.
    resetTape();
    const from = Math.max(0, i - 80);
    for (let k = from; k <= i; k++) pushTrades(k);
    idx = i;
    lastTape = i;
    render(i, { animate: false });
  }

  function step() {
    if (idx >= events.length - 1) {
      idx = 0;
      resetTape();
      lastTape = -1;
    } else idx += 1;
    if (idx > lastTape) {
      pushTrades(idx);
      lastTape = idx;
    }
    render(idx);
  }

  function schedule() {
    clearInterval(timer);
    if (!playing) return;
    timer = setInterval(step, 520 / speed);
  }

  function setPlaying(p) {
    playing = p;
    playBtn.textContent = p ? "Pause" : "Play";
    playBtn.setAttribute("aria-pressed", String(p));
    schedule();
  }

  playBtn.addEventListener("click", () => setPlaying(!playing));
  speedBox.addEventListener("click", (ev) => {
    const b = ev.target.closest("button");
    if (!b) return;
    speed = Number(b.dataset.s);
    speedBox.querySelectorAll("button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    schedule();
  });
  scrub.addEventListener("input", () => {
    seek(Number(scrub.value));
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) clearInterval(timer);
    else schedule();
  });

  seek(0);
  // Only run while on screen, and start paused for users who prefer reduced motion.
  playing = !reduced();
  playBtn.textContent = playing ? "Pause" : "Play";
  playBtn.setAttribute("aria-pressed", String(playing));
  const card = document.getElementById("book-card");
  const io = new IntersectionObserver(
    (entries) => {
      for (const en of entries) {
        if (en.isIntersecting) schedule();
        else clearInterval(timer);
      }
    },
    { threshold: 0.2 },
  );
  io.observe(card);
  onVisible(card, () => {});
}
