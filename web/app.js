// Entry point: wires data to every section, plus theme, nav highlight, scroll
// progress and scroll-reveal.

import { initBook } from "./book.js";
import { heroStats, makerSection } from "./charts.js";
import { surfaceSection, hedgeSection, etfSection, etfMarketSection, riskSection, stackSection } from "./charts2.js";

const data = window.QUOTELINE;

function fail(msg) {
  const d = document.createElement("div");
  d.style.cssText = "padding:32px;font:16px system-ui;color:#d03b3b";
  d.textContent = msg;
  document.body.prepend(d);
}

if (!data) {
  fail("data.js is missing. Run: quoteline export --out web/data && node web/build-data.mjs web/data web/data.js");
} else {
  // ---- theme --------------------------------------------------------------
  const root = document.documentElement;
  const saved = localStorage.getItem("ql-theme");
  if (saved) root.dataset.theme = saved;
  document.getElementById("theme").addEventListener("click", () => {
    const dark = getComputedStyle(root).colorScheme.startsWith("dark");
    const next = dark ? "light" : "dark";
    root.dataset.theme = next;
    localStorage.setItem("ql-theme", next);
  });

  // ---- build sections -----------------------------------------------------
  const sections = [
    ["hero stats", () => heroStats(data)],
    ["order book", () => initBook(data.replay)],
    ["market maker", () => makerSection(data)],
    ["surface", () => surfaceSection(data)],
    ["hedging", () => hedgeSection(data)],
    ["etf", () => etfSection(data)],
    ["etf market", () => etfMarketSection(data)],
    ["risk", () => riskSection(data)],
    ["stack", () => stackSection(data)],
  ];
  for (const [name, build] of sections) {
    try {
      build();
    } catch (err) {
      console.error(`section "${name}" failed`, err);
      fail(`Section "${name}" failed to render: ${err.message}`);
    }
  }

  // ---- scroll reveal ------------------------------------------------------
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      }
    },
    { threshold: 0.12, rootMargin: "0px 0px -6% 0px" },
  );
  document.querySelectorAll(".reveal").forEach((n) => (reduce ? n.classList.add("in") : io.observe(n)));

  // ---- progress bar + nav highlight --------------------------------------
  const bar = document.getElementById("progress");
  const links = [...document.querySelectorAll("a.link")];
  const targets = links.map((a) => document.querySelector(a.getAttribute("href")));
  let ticking = false;
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      const max = document.documentElement.scrollHeight - innerHeight;
      bar.style.transform = `scaleX(${max > 0 ? Math.min(1, scrollY / max) : 0})`;
      let cur = -1;
      targets.forEach((t, i) => {
        if (t && t.getBoundingClientRect().top < innerHeight * 0.4) cur = i;
      });
      links.forEach((a, i) => a.setAttribute("aria-current", String(i === cur)));
      ticking = false;
    });
  }
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();
}
