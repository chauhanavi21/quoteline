(** A small multi-asset market: three stocks and an ETF on them, where the ETF
    has a real limit order book.

    This ties the {!Basket} arithmetic to the matching engine. The stocks follow
    correlated random walks (one common factor plus idiosyncratic noise); the
    ETF's fundamental value is the basket NAV. The ETF trades on its own
    {!Book.t}, driven by {!Sim.Flow}, with the fundamental supplied from the
    NAV. Passive orders quote around a lagged NAV, so the ETF book is sometimes
    stale; informed traders trade the ETF toward NAV.

    Two market makers quote the ETF. Both are Avellaneda-Stoikov, differing only
    in the reference price they quote around:

    - {b Own_mid}: the ETF book's own mid;
    - {b Nav_blend}: [(1 - w) * book mid + w * NAV]. NAV is computed from the
      {e observable} stock prices, never from the hidden fundamental.

    Everything is synthetic and seeded. *)

type config =
  { sim : Sim.config  (** flow parameters for the ETF book; [fundamental_vol] is unused *)
  ; stock_vol : float
        (** per-stock volatility in {e currency units} per sqrt(second). The NAV's
            volatility is [stock_vol] times a basket factor (about 6.1 for the default
            basket and [factor_share = 0.6]), in currency units; multiply by
            [Price.ticks_per_unit] for ticks. *)
  ; factor_share : float  (** share of stock variance from the common factor, in [0, 1] *)
  ; basket : Basket.constituent list  (** starting prices and weights *)
  ; quoter : Mm.Quoter.params
  ; nav_weight : float  (** [w] above: 0 = own mid only, 1 = NAV only *)
  }

type result =
  { total_pnl : float  (** ticks *)
  ; attribution : Mm.Backtest.attribution
  ; volume : int
  ; fills : int
  ; max_abs_inventory : int
  ; nav_tracking_error : float
      (** rms of (ETF book mid - NAV) in ticks, over events where both exist *)
  }

(** @raise Invalid_argument if [nav_weight] or [factor_share] is outside [0, 1]
    or the basket is empty. *)
val run : config -> result

(** The default three-stock basket and config used by the export. *)
val default_config : config
