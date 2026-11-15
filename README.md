# Quoteline

A limit order book, a market-making lab, an options pricer with a fitted
volatility surface, a delta-hedging simulator and an ETF arbitrage engine,
written in OCaml, with a browser view of the results.

Everything runs on **simulated data**. This is an engineering and research
project; it makes no claim about real-market profit.

Open [`web/index.html`](web/index.html) in a browser (double-click, no server)
to see the engine's output: a replayable order book and every result below as
an interactive chart.

## What is in it

| Part | What it does | Where |
|---|---|---|
| Order book | Price-time priority matching, limit / market / IOC / cancel, trades at the resting price | `lib/book` |
| Simulator | Seeded event stream with a hidden fundamental price, informed traders and per-order lifetimes. Same seed, same bytes | `lib/sim` |
| Market maker | Avellaneda-Stoikov quoting, post-only, inventory limits; PnL split into spread / adverse selection / inventory | `lib/mm` |
| Options | Black-Scholes and Greeks, implied vol, SVI surface fit with a butterfly-arbitrage check, delta hedging | `lib/options` |
| ETF | NAV and creation/redemption arbitrage signal with all-in costs; least-squares partial-basket hedge | `lib/etf` |
| Risk | Historical and normal VaR and expected shortfall | `lib/risk` |
| Research (Python) | Independent re-implementations used as cross-checks | `research/` |
| Web view | Plain HTML/CSS/JS, no framework | `web/` |

Prices are integer ticks and quantities are non-negative by construction
(abstract `Price.t` and `Qty.t`), so the engine never touches floating point and
a negative size cannot be represented.

## Results, and how each was checked

### The matching engine agrees with an independent implementation

`research/reference_book.py` is a deliberately naive order book (plain lists,
linear scans) written with no shared code. Replaying the simulator's 20,000
events through it produces **exactly the same 3,315 trades** as the OCaml
engine: same takers, makers, prices and quantities, in the same order. The book
is never crossed at any step.

The checker can fail: corrupting the expected trades by one tick, one lot, a
swap or a deletion is caught at exactly the corrupted index every time.

### Option prices and Greeks agree with Monte Carlo

`research/mc_options.py` prices five options by simulation (antithetic
variates, pathwise derivatives), using only the standard library. All 20
comparisons (price, delta, vega, rho for five options) land within 4 standard
errors of the OCaml closed form; the largest |z| was 2.33. A separate run over
30 independent seeds put the mean z-scores within 1.6 standard errors of zero,
so there is no systematic bias.

### The market maker's edge is small but positive in this simulator

One backtest is one path, and the path shown first on the web page (seed 42)
ended at **-0.18**. Over **24 independent seeds** the picture differs:

| Component | Mean | 95% bootstrap interval |
|---|---|---|
| Spread capture | +11.23 | [+10.63, +11.80] |
| Adverse selection | -6.63 | [-7.07, -6.18] |
| Inventory | -3.06 | [-3.54, -2.59] |
| **Total** | **+1.54** | **[+0.88, +2.15]** |

19 of 24 seeds were profitable. The Python bootstrap in
`research/bootstrap_pnl.py` gives the same mean and an interval of
[+0.885, +2.151]. The three components sum to the total on every seed to
1e-15.

Read this as a demonstration of the mechanism. The informed traders, their news
and the order-flow parameters are my own assumptions, and there is no latency,
fee or queue-position model. With the default news volatility, informed flow has
almost no effect on the maker; the sweep on the page uses a larger value, where
more informed flow measurably worsens adverse selection per lot.

### Delta hedging behaves as theory says

Selling a call at 20% vol and hedging at matched volatility: the mean hedged PnL
is near zero and the standard deviation falls like 1/sqrt(trades). The product
std x sqrt(trades) stays within a narrow band from 12 to 504 hedges. When the
stock's real volatility differs, the mean PnL tracks the gamma-weighted variance
gap (Carr-Lewis); path by path the formula correlates 0.99+ with the realised
PnL.

### Volatility surface

SVI is fitted per expiry to implied vols recovered from noisy prices. On
noiseless data it recovers all five parameters exactly; with 0.5% price noise
the worst slice has total-variance RMSE of about 6e-5, and every fitted slice
has positive butterfly density (no static arbitrage over the plotted range).

## Performance, honestly

`dune exec bench/bench.exe` on an Intel Core Ultra 7 265H, 31 GB RAM (median of
7 runs, event generation excluded):

| Workload | Resting orders | Events / s | ns / event |
|---|---|---|---|
| Default (shallow book) | 171 | 3.58 M | 279 |
| Deep book | 4,850 | 1.29 M | 772 |
| Very deep book | 19,937 | **183 K** | **5,466** |
| Heavy matching (60% market orders) | 12 | 3.96 M | 253 |

**Throughput collapses as the book deepens, and the cause is known.** On the
deep book a limit order costs about 640 ns and a market order about 1,000 ns,
but a cancel costs about 4,900 ns. Cancels are 30% of events and take 78% of the
time. `Book.cancel` finds the order by scanning its price level's list and then
filters that list, so a cancel costs time proportional to the orders at that
price. Fixing it means an id-indexed structure per level; I have not done that.

Note that the book is a persistent (immutable) structure. That is what makes
replay, forking and property testing simple, and it costs allocation on every
operation. These figures are single-threaded and say nothing about network or
disk latency.

## Testing

73 test cases (`dune runtest`): expect tests with hand-checked values, randomised
property tests (the book is never crossed, traded volume is conserved, replaying
is deterministic), and statistical tests (hedging error scaling, the gamma-PnL formula,
sampler moments, VaR/ES against the normal closed form).

Each test was also **mutation-checked**: I broke the code it covers on purpose
and confirmed the test failed. That caught real gaps. The first SVI arbitrage
test passed even with the density formula's sign flipped, so I added a
hand-computed case that does catch it.

## Things I got wrong along the way

- The first simulator took O(n^2) time (20,000 events in 11 s) because of how
  it tracked orders to cancel. The book itself was fast; the bookkeeping was not.
  Now 160,000 events take 1.4 s.
- The first simulator produced no adverse selection at all, even with 90% informed
  traders, because random cancels left 16,000 stale orders and the quotes never
  followed the news. Per-order lifetimes fixed it.
- My first test of that effect compared totals, which fall as fills fall, and
  used a regime where the effect cannot appear. It now compares per lot.
- The page first said the maker "lost money" from a single unlucky seed. The
  24-seed run says otherwise, so the page now shows both.

## Limitations

- Synthetic data only; the strategy's edge is a property of my simulator.
- No latency, fees, queue position, or market impact beyond the book itself.
- One instrument. The ETF and options modules are not wired into the book.
- Cancel cost grows with level depth (above).
- SVI is fitted per slice, with no calendar-spread arbitrage check across expiries.

## Build and run

Built and tested with OCaml 5.5.2 and dune 3.25 (native opam on Windows). Nothing
older than that has been tried.

```
opam install dune ppx_expect ppx_inline_test
dune build
dune runtest
dune exec bench/bench.exe

dune exec quoteline -- run-sim --seed 42 --events 20000 --out out
dune exec quoteline -- export  --seed 42 --events 20000 --out web/data
node web/build-data.mjs web/data web/data.js
node web/build-bundle.mjs
```

Python checks use only the standard library:

```
python research/reference_book.py out/events.csv out/trades.csv
python research/mc_options.py
python research/bootstrap_pnl.py 24 20000
```
