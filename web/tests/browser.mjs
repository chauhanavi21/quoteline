// Browser tests for the page. Opens web/index.html from disk in a real
// Chromium-based browser, drives it like a user and fails on any regression.
//
//   cd web/tests && npm install && npm test
//
// Set CHROME_PATH to use a specific browser; otherwise common install
// locations for Chrome, Edge and Chromium are tried on Windows, macOS and Linux.

import { chromium } from "playwright-core";
import { existsSync } from "node:fs";
import { pathToFileURL, fileURLToPath } from "node:url";
import { resolve, dirname } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const page_url = pathToFileURL(resolve(here, "..", "index.html")).href;

function findBrowser() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  const candidates = [
    "C:/Program Files/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
    "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/snap/bin/chromium",
  ];
  return candidates.find((p) => existsSync(p));
}

const exe = findBrowser();
if (!exe) {
  console.error("No Chrome, Edge or Chromium found. Install one or set CHROME_PATH.");
  process.exit(2);
}

let failed = 0;
let passed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`);
  ok ? passed++ : failed++;
}

const browser = await chromium.launch({ executablePath: exe, headless: true });

// Open the page and scroll through it so reveal and draw animations run.
async function open(contextOptions) {
  const ctx = await browser.newContext(contextOptions);
  const page = await ctx.newPage();
  const errors = [];
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("requestfailed", (r) => errors.push("requestfailed: " + r.url()));
  await page.goto(page_url, { waitUntil: "load" });
  return { ctx, page, errors };
}

async function scrollThrough(page) {
  const h = await page.evaluate(() => document.documentElement.scrollHeight);
  for (let y = 0; y < h; y += 500) {
    await page.evaluate((yy) => window.scrollTo(0, yy), y);
    await page.waitForTimeout(110);
  }
  await page.waitForTimeout(1500);
}

// ---------------------------------------------------------------- render
for (const theme of ["dark", "light"]) {
  const { ctx, page, errors } = await open({ viewport: { width: 1280, height: 900 }, colorScheme: theme });
  await scrollThrough(page);
  const r = await page.evaluate(() => ({
    cards: document.querySelectorAll(".card").length,
    svgs: document.querySelectorAll(".chart svg").length,
    failed: [...document.querySelectorAll("body > div")].filter((d) => d.textContent.startsWith("Section")).length,
    stuck: document.querySelectorAll(".reveal:not(.in)").length,
    overflow: document.documentElement.scrollWidth > innerWidth + 1,
    stats: [...document.querySelectorAll(".stat .value")].map((n) => n.textContent),
  }));
  check(`${theme}: every section renders`, r.failed === 0 && r.cards >= 19 && r.svgs >= 15, `${r.cards} cards, ${r.svgs} charts`);
  check(`${theme}: nothing stuck hidden`, r.stuck === 0, `${r.stuck} stuck`);
  check(`${theme}: no horizontal overflow`, !r.overflow);
  check(`${theme}: hero stats counted up`, r.stats.length === 4 && r.stats.every((t) => t !== "0"), r.stats.join(" | "));
  check(`${theme}: no console errors or failed requests`, errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// ----------------------------------------------------------- interaction
{
  const { ctx, page, errors } = await open({ viewport: { width: 1280, height: 900 }, colorScheme: "dark" });
  await page.evaluate(() => document.getElementById("book").scrollIntoView({ behavior: "instant" }));
  await page.waitForTimeout(600);

  const e0 = await page.textContent("#event-count");
  await page.waitForTimeout(2500);
  check("replay advances while playing", e0 !== (await page.textContent("#event-count")));

  await page.click("#play");
  const p0 = await page.textContent("#event-count");
  await page.waitForTimeout(1500);
  check("pause holds the position", p0 === (await page.textContent("#event-count")));

  await page.fill("#scrub", "300");
  await page.dispatchEvent("#scrub", "input");
  await page.waitForTimeout(300);
  check("scrub jumps to the chosen event", (await page.textContent("#event-count")).startsWith("event 301 of 400"));
  check("tape fills with trades after scrubbing", (await page.$$eval("#tape li:not(.empty)", (n) => n.length)) > 0);

  const crossed = await page.evaluate(() =>
    window.QUOTELINE.replay.events.filter((e) => e.bids[0] && e.asks[0] && e.bids[0].price >= e.asks[0].price).length);
  check("the replayed book is never crossed", crossed === 0, `${crossed} crossed`);

  const before = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  await page.click("#theme");
  check("theme toggle changes the page colour", before !== (await page.evaluate(() => getComputedStyle(document.body).backgroundColor)));

  await page.evaluate(() => document.getElementById("maker").scrollIntoView({ behavior: "instant" }));
  await page.waitForTimeout(700);
  const cards = await page.$$("#maker-grid .card");
  await (await cards[0].$(".view-toggle")).click();
  const tableOn = await cards[0].$eval(".tbl", (n) => getComputedStyle(n).display !== "none" && n.querySelectorAll("tr").length > 1);
  check("table view replaces the chart", (await cards[0].getAttribute("data-view")) === "table" && tableOn);
  await (await cards[0].$(".view-toggle")).click();

  const overlay = await cards[1].$("svg rect[tabindex='0']");
  const box = await overlay.boundingBox();
  await page.mouse.move(box.x + box.width * 0.4, box.y + box.height / 2);
  await page.waitForTimeout(250);
  check("hover shows a tooltip with a value", await cards[1].$eval(".tip", (n) => n.classList.contains("on") && n.textContent.length > 4));
  await page.mouse.move(5, 5);
  await page.waitForTimeout(250);
  check("the tooltip hides on leave", await cards[1].$eval(".tip", (n) => !n.classList.contains("on")));
  await overlay.focus();
  await page.keyboard.press("ArrowRight");
  check("keyboard arrows drive the tooltip", await cards[1].$eval(".tip", (n) => n.classList.contains("on")));

  // Tooltip must show the data point under the pointer, not a neighbour.
  const pnl = await page.evaluate(() => window.QUOTELINE.backtest.pnl);
  await page.mouse.move(box.x + box.width * 0.25, box.y + box.height / 2);
  await page.waitForTimeout(200);
  const tip = await cards[1].$eval(".tip", (n) => n.innerText.replace(/\s+/g, " "));
  const idx = Math.round(0.25 * (pnl.length - 1));
  const near = pnl.slice(idx - 2, idx + 3).map((v) => v.toFixed(2).replace(/^-0\.00$/, "0.00"));
  const shown = (tip.match(/-?\d+\.\d+$/) || [""])[0];
  check("the tooltip value matches the underlying data", near.includes(shown), `shows ${shown}, data near ${near.join(", ")}`);

  const sweep = (await page.$$("#maker-grid .card"))[2];
  await sweep.scrollIntoViewIfNeeded();
  const lines0 = await sweep.$$eval("svg path.line", (n) => n.length);
  await (await sweep.$$(".legend button"))[1].click();
  check("legend toggle hides a series", (await sweep.$$eval("svg path.line", (n) => n.length)) === lines0 - 1);

  await page.click('a.link[href="#etf"]');
  await page.waitForTimeout(1200);
  check("nav link scrolls to its section", Math.abs(await page.$eval("#etf", (n) => Math.round(n.getBoundingClientRect().top))) < 120);
  check("no console errors during the session", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// -------------------------------------------------------- reduced motion
{
  const { ctx, page, errors } = await open({ viewport: { width: 1280, height: 900 }, reducedMotion: "reduce" });
  await page.waitForTimeout(2500); // no scrolling: content must already be visible
  const r = await page.evaluate(() => {
    const op = (n) => +getComputedStyle(n).opacity;
    return {
      hidden: [...document.querySelectorAll(".reveal")].filter((n) => op(n) < 0.99).length,
      dashed: [...document.querySelectorAll(".chart path.line")].filter((n) => getComputedStyle(n).strokeDasharray !== "none").length,
      collapsed: [...document.querySelectorAll(".chart .grow")].filter((n) => {
        const t = getComputedStyle(n).transform;
        return t !== "none" && t !== "matrix(1, 0, 0, 1, 0, 0)";
      }).length,
      play: document.getElementById("play").textContent,
    };
  });
  const e0 = await page.textContent("#event-count");
  await page.waitForTimeout(1800);
  check("reduced motion: content visible without scrolling", r.hidden === 0, `${r.hidden} hidden`);
  check("reduced motion: lines are not mid-draw", r.dashed === 0);
  check("reduced motion: bars are full size", r.collapsed === 0);
  check("reduced motion: the replay does not auto-play", r.play === "Play" && e0 === (await page.textContent("#event-count")));
  check("reduced motion: no console errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// ------------------------------------------------------------------ mobile
{
  const { ctx, page, errors } = await open({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, colorScheme: "dark" });
  await scrollThrough(page);
  const r = await page.evaluate(() => ({ vw: document.documentElement.clientWidth, sw: document.documentElement.scrollWidth }));
  check("mobile: no horizontal scroll at 390px", r.sw <= r.vw + 1, `scrollWidth ${r.sw}`);
  check("mobile: no console errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

await browser.close();
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
