"""Monte Carlo cross-check of the OCaml Black-Scholes pricer and Greeks.

The OCaml code prices with the closed form. Here the same options are priced by
simulating the stock directly, using only the standard library, so nothing is
shared with lib/options. The price is the discounted mean payoff under the
risk-neutral measure; delta, vega and rho come from the pathwise derivative
(differentiate the payoff along each path), which needs no bump size.

Each estimate carries a standard error, and a check passes only if the closed
form lies within 4 standard errors of the Monte Carlo value.
"""

from __future__ import annotations

import json
import math
import random
import statistics
import subprocess
import sys


def norm_cdf(x: float) -> float:
    return 0.5 * math.erfc(-x / math.sqrt(2.0))


def bs_price(kind, s, k, r, vol, t):
    d1 = (math.log(s / k) + (r + 0.5 * vol * vol) * t) / (vol * math.sqrt(t))
    d2 = d1 - vol * math.sqrt(t)
    if kind == "call":
        return s * norm_cdf(d1) - k * math.exp(-r * t) * norm_cdf(d2)
    return k * math.exp(-r * t) * norm_cdf(-d2) - s * norm_cdf(-d1)


def mc_estimates(kind, s, k, r, vol, t, n, seed):
    """Return {name: (estimate, standard_error)} for price, delta, vega, rho.

    Antithetic variates: each normal draw z is paired with -z, which halves the
    variance for these monotone payoffs. Pathwise derivatives, with
    S_T = s * exp((r - vol^2/2) t + vol sqrt(t) z):
        dS_T/ds   = S_T / s
        dS_T/dvol = S_T * (sqrt(t) z - vol t)
        dS_T/dr   = S_T * t
    """
    rng = random.Random(seed)
    disc = math.exp(-r * t)
    sq = math.sqrt(t)
    sign = 1.0 if kind == "call" else -1.0
    price, delta, vega, rho = [], [], [], []
    for _ in range(n):
        z = rng.gauss(0.0, 1.0)
        p = d = v = rr = 0.0
        for zz in (z, -z):
            st = s * math.exp((r - 0.5 * vol * vol) * t + vol * sq * zz)
            itm = (st > k) if kind == "call" else (st < k)
            payoff = max(sign * (st - k), 0.0)
            p += payoff
            if itm:
                d += sign * st / s
                v += sign * st * (sq * zz - vol * t)
                rr += sign * st * t
        price.append(disc * p / 2)
        delta.append(disc * d / 2)
        vega.append(disc * v / 2)
        # rho = d/dr [disc * E payoff] = -t * price + disc * E[d payoff / dr]
        rho.append(-t * disc * p / 2 + disc * rr / 2 * k / k)
    out = {}
    for name, xs in (("price", price), ("delta", delta), ("vega", vega), ("rho", rho)):
        m = statistics.fmean(xs)
        se = statistics.stdev(xs) / math.sqrt(len(xs))
        out[name] = (m, se)
    return out


def bs_greeks(kind, s, k, r, vol, t):
    d1 = (math.log(s / k) + (r + 0.5 * vol * vol) * t) / (vol * math.sqrt(t))
    d2 = d1 - vol * math.sqrt(t)
    pdf = math.exp(-0.5 * d1 * d1) / math.sqrt(2 * math.pi)
    disc = math.exp(-r * t)
    vega = s * pdf * math.sqrt(t)
    if kind == "call":
        return {"delta": norm_cdf(d1), "vega": vega, "rho": t * k * disc * norm_cdf(d2)}
    return {"delta": norm_cdf(d1) - 1.0, "vega": vega, "rho": -t * k * disc * norm_cdf(-d2)}


CASES = [
    ("call", 100, 100, 0.05, 0.20, 1.0),
    ("put", 100, 100, 0.05, 0.20, 1.0),
    ("call", 100, 120, 0.03, 0.35, 0.5),
    ("put", 90, 110, 0.04, 0.15, 0.25),
    ("call", 120, 100, 0.02, 0.50, 2.0),
]


def run(n=200_000, seed=2024, tol_se=4.0):
    rows, ok = [], True
    for kind, s, k, r, vol, t in CASES:
        est = mc_estimates(kind, s, k, r, vol, t, n, seed)
        exact = {"price": bs_price(kind, s, k, r, vol, t), **bs_greeks(kind, s, k, r, vol, t)}
        for name in ("price", "delta", "vega", "rho"):
            m, se = est[name]
            z = (m - exact[name]) / se if se > 0 else 0.0
            passed = abs(z) <= tol_se
            ok &= passed
            rows.append(
                {"case": f"{kind} S={s} K={k} r={r} vol={vol} T={t}", "measure": name,
                 "closed_form": exact[name], "monte_carlo": m, "std_error": se, "z": z, "pass": passed}
            )
    return rows, ok


if __name__ == "__main__":
    rows, ok = run()
    last = None
    for r in rows:
        if r["case"] != last:
            print(f"\n{r['case']}")
            last = r["case"]
        print(f"  {r['measure']:5s} closed={r['closed_form']:10.5f}  mc={r['monte_carlo']:10.5f} "
              f"+/- {r['std_error']:.5f}  z={r['z']:+5.2f}  {'ok' if r['pass'] else 'FAIL'}")
    print("\nALL WITHIN 4 STANDARD ERRORS" if ok else "\nMISMATCH")
    sys.exit(0 if ok else 1)
