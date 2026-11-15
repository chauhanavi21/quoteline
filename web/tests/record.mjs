// Record a short tour of the page as a WebM, and take still screenshots.
//
//   cd web/tests && npm install && npm run record
//
// Writes ../../docs/tour.webm and ../../docs/*.png. The tour plays the order
// book, scrolls through the charts, hovers one for a tooltip and flips the
// theme, at an unhurried pace so it can be followed.

import { chromium } from "playwright-core";
import { existsSync, mkdirSync, readdirSync, renameSync, rmSync } from "node:fs";
import { pathToFileURL, fileURLToPath } from "node:url";
import { resolve, dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const page_url = pathToFileURL(resolve(here, "..", "index.html")).href;
const docs = resolve(here, "..", "..", "docs");
const tmp = resolve(here, ".rec");

function findBrowser() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  return [
    "C:/Program Files/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
  ].find((p) => existsSync(p));
}
const exe = findBrowser();
if (!exe) {
  console.error("No Chrome, Edge or Chromium found. Set CHROME_PATH.");
  process.exit(2);
}

rmSync(tmp, { recursive: true, force: true });
mkdirSync(tmp, { recursive: true });
mkdirSync(docs, { recursive: true });

const size = { width: 1280, height: 720 };
// The video is recorded at 960x540 to keep it small; the stills use the full 1280x720.
const videoSize = { width: 960, height: 540 };
const browser = await chromium.launch({ executablePath: exe, headless: true });
const ctx = await browser.newContext({ viewport: size, colorScheme: "dark", recordVideo: { dir: tmp, size: videoSize } });
const page = await ctx.newPage();
await page.goto(page_url, { waitUntil: "load" });
await page.waitForTimeout(1800);

const go = async (id, wait = 2200) => {
  await page.evaluate((i) => document.getElementById(i)?.scrollIntoView({ behavior: "smooth", block: "start" }), id);
  await page.waitForTimeout(wait);
};
const shot = (name) => page.screenshot({ path: join(docs, name) });

await shot("hero.png");

// order book: let it play
await go("book", 4000);
await shot("order-book.png");

// market maker: hover the PnL line for a tooltip
await go("maker", 1800);
await page.evaluate(() => window.scrollBy({ top: 420, behavior: "smooth" }));
await page.waitForTimeout(1400);
const cards = await page.$$("#maker-grid .card");
const box = await (await cards[1].$("svg rect[tabindex='0']")).boundingBox();
for (const f of [0.2, 0.5, 0.8]) {
  await page.mouse.move(box.x + box.width * f, box.y + box.height / 2, { steps: 10 });
  await page.waitForTimeout(500);
}
await shot("market-maker.png");

// the other sections, one stop each
await go("surface", 1500);
await go("hedge", 1500);
await shot("hedging.png");
await go("etf", 1500);
await shot("etf.png");
await go("risk", 1500);

// flip the theme once
await page.click("#theme");
await page.waitForTimeout(1200);
await shot("risk-light.png");
await page.click("#theme");
await page.waitForTimeout(500);

await ctx.close();
await browser.close();

const vid = readdirSync(tmp).find((f) => f.endsWith(".webm"));
if (!vid) {
  console.error("no video was produced");
  process.exit(1);
}
renameSync(join(tmp, vid), join(docs, "tour.webm"));
rmSync(tmp, { recursive: true, force: true });
console.log("wrote docs/tour.webm (git-ignored: host it elsewhere) and screenshots in", docs);
