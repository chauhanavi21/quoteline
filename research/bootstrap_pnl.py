"""Is the market maker's PnL distinguishable from zero?

A single backtest is one path, so it says little. This runs the OCaml backtest
over many seeds (each seed is an independent simulated market), then uses a
percentile bootstrap on the per-seed results to put a 95% interval on the mean
of each PnL component.

    python bootstrap_pnl.py [n_seeds] [events]

Needs the built `quoteline` executable; it calls it through `dune exec`.
"""

from __future__ import annotations

import json
import os
import random
import statistics
import subprocess
import sys
import tempfile


def run_seed(seed: int, events: int, repo: str) -> dict:
    """Run `quoteline export` for one seed and return backtest.json's summary."""
    with tempfile.TemporaryDirectory() as out:
        cmd = ["opam", "exec", "--switch=default", "--", "dune", "exec", "quoteline", "--",
               "export", "--seed", str(seed), "--events", str(events), "--out", out]
        p = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"seed {seed} failed:\n{p.stderr[-600:]}")
        with open(os.path.join(out, "backtest.json"), encoding="utf-8") as f:
            return json.load(f)["summary"]


def bootstrap_ci(xs, n_boot=10_000, alpha=0.05, seed=1):
    """Percentile bootstrap CI for the mean."""
    rng = random.Random(seed)
    n = len(xs)
    means = sorted(statistics.fmean(rng.choices(xs, k=n)) for _ in range(n_boot))
    lo = means[int(n_boot * alpha / 2)]
    hi = means[int(n_boot * (1 - alpha / 2)) - 1]
    return statistics.fmean(xs), lo, hi


def main():
    n_seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    events = int(sys.argv[2]) if len(sys.argv) > 2 else 20_000
    repo = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    rows = []
    for seed in range(1, n_seeds + 1):
        rows.append(run_seed(seed, events, repo))
        print(f"  seed {seed:2d}: pnl {rows[-1]['total_pnl']:+.3f}", flush=True)

    print(f"\n{n_seeds} independent seeds, {events:,} events each. Units: currency.")
    print(f"{'component':20s} {'mean':>9s}   95% bootstrap CI        verdict")
    for key in ("spread_capture", "adverse_selection", "inventory", "total_pnl"):
        xs = [r[key] for r in rows]
        m, lo, hi = bootstrap_ci(xs)
        verdict = "different from 0" if lo > 0 or hi < 0 else "cannot rule out 0"
        print(f"{key:20s} {m:+9.3f}   [{lo:+8.3f}, {hi:+8.3f}]   {verdict}")

    # The three parts must sum to the total on every single seed.
    worst = max(abs(r["spread_capture"] + r["adverse_selection"] + r["inventory"] - r["total_pnl"]) for r in rows)
    print(f"\nattribution identity: largest |parts - total| over all seeds = {worst:.2e}")
    return 0 if worst < 1e-6 else 1


if __name__ == "__main__":
    sys.exit(main())
