"""A deliberately naive limit order book, written independently of the OCaml engine.

It uses plain lists and linear scans, with no persistent data structures, so it
shares no design (and no bugs) with lib/book. `verify_events` replays the
simulator's events.csv through it and checks that it produces exactly the
trades the OCaml engine wrote to trades.csv.

Price-time priority: best price first, and within a price the oldest order
first. A trade prints at the resting order's price.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass, field


@dataclass
class Order:
    id: int
    side: str  # "BUY" or "SELL"
    price: int  # integer ticks
    qty: int
    seq: int  # arrival order, for time priority


@dataclass
class Book:
    bids: list[Order] = field(default_factory=list)
    asks: list[Order] = field(default_factory=list)
    seq: int = 0

    def _best(self, side: str):
        """Best resting order on `side` (highest bid / lowest ask, oldest first)."""
        book = self.bids if side == "BUY" else self.asks
        if not book:
            return None
        if side == "BUY":
            return min(book, key=lambda o: (-o.price, o.seq))
        return min(book, key=lambda o: (o.price, o.seq))

    def add(self, id: int, side: str, price: int, qty: int, rest: bool):
        """Match, then rest the remainder if `rest`. Returns [(taker, maker, price, qty)]."""
        self.seq += 1
        trades = []
        opposite = "SELL" if side == "BUY" else "BUY"
        remaining = qty
        while remaining > 0:
            best = self._best(opposite)
            if best is None:
                break
            crosses = best.price <= price if side == "BUY" else best.price >= price
            if not crosses:
                break
            fill = min(remaining, best.qty)
            trades.append((id, best.id, best.price, fill))
            best.qty -= fill
            remaining -= fill
            if best.qty == 0:
                (self.asks if opposite == "SELL" else self.bids).remove(best)
        if rest and remaining > 0:
            (self.bids if side == "BUY" else self.asks).append(Order(id, side, price, remaining, self.seq))
        return trades

    def cancel(self, id: int) -> bool:
        for book in (self.bids, self.asks):
            for o in book:
                if o.id == id:
                    book.remove(o)
                    return True
        return False  # already filled: a harmless no-op

    def crossed(self) -> bool:
        b, a = self._best("BUY"), self._best("SELL")
        return b is not None and a is not None and b.price >= a.price


def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def verify_events(events_csv: str, trades_csv: str):
    """Replay events.csv and compare against trades.csv. Returns a summary dict."""
    events = read_csv(events_csv)
    expected = read_csv(trades_csv)
    book = Book()
    got = []
    crossed_after = 0
    market_limit = {"BUY": 2**62, "SELL": 0}
    for e in events:
        kind = e["kind"]
        id = int(e["id"])
        if kind == "CANCEL":
            book.cancel(id)
        elif kind == "LIMIT":
            for t in book.add(id, e["side"], int(e["price_ticks"]), int(e["qty"]), rest=True):
                got.append((int(e["time_us"]), *t))
        elif kind == "MARKET":
            for t in book.add(id, e["side"], market_limit[e["side"]], int(e["qty"]), rest=False):
                got.append((int(e["time_us"]), *t))
        else:
            raise ValueError(f"unknown event kind {kind!r}")
        if book.crossed():
            crossed_after += 1
    want = [
        (int(r["time_us"]), int(r["taker"]), int(r["maker"]), int(r["price_ticks"]), int(r["qty"]))
        for r in expected
    ]
    first_diff = next((i for i, (g, w) in enumerate(zip(got, want)) if g != w), None)
    return {
        "events": len(events),
        "trades_expected": len(want),
        "trades_reference": len(got),
        "identical": got == want,
        "first_difference_index": first_diff,
        "crossed_states": crossed_after,
    }


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 3:
        sys.exit("usage: python reference_book.py <events.csv> <trades.csv>")
    r = verify_events(sys.argv[1], sys.argv[2])
    for k, v in r.items():
        print(f"{k}: {v}")
    sys.exit(0 if r["identical"] and r["crossed_states"] == 0 else 1)
