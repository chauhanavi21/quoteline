(** Discrete delta-hedging of a short option, on simulated geometric Brownian
    motion.

    The trader sells one option at the Black-Scholes price for [implied_vol],
    then rebalances a stock position to the model delta (also computed with
    [implied_vol]) at [steps] equally spaced times, financing at [rate]. The
    stock really moves with [real_vol]. All values are at expiry (not
    discounted), per one option.

    Two textbook facts this module lets you check:
    - with [real_vol = implied_vol], the hedging error shrinks like
      [1 / sqrt steps];
    - with [real_vol <> implied_vol], the PnL is, to first order, the
      gamma-weighted gap between the two variances (Carr-Lewis):
      [sum_j e^(r (T - t_j+1)) * 0.5 * Gamma_j * (implied_vol^2 * S_j^2 * dt - dS_j^2)]. *)

type config =
  { kind : Bs.kind
  ; spot : float
  ; strike : float
  ; rate : float
  ; drift : float  (** real-world drift of the stock *)
  ; implied_vol : float  (** vol used for pricing and for the hedge ratio *)
  ; real_vol : float  (** vol the stock actually follows *)
  ; expiry : float
  ; steps : int  (** number of rebalancing intervals *)
  }

type path_result =
  { premium : float  (** price received at inception *)
  ; pnl : float  (** hedged PnL at expiry *)
  ; pnl_gamma_formula : float  (** the Carr-Lewis approximation of [pnl] *)
  ; spots : float array  (** [steps + 1] values, starting at [spot] *)
  ; deltas : float array  (** [steps] hedge ratios held over each interval *)
  }

(** Simulate one path.
    @raise Invalid_argument if [steps <= 0] or [expiry <= 0]. *)
val simulate : config -> Random.State.t -> path_result

type summary =
  { mean_pnl : float
  ; std_pnl : float
  ; paths : int
  }

(** Run [paths] independent paths from a single seed. *)
val summarise : config -> seed:int -> paths:int -> summary
