(** SVI (stochastic volatility inspired) parameterisation of one expiry slice
    of the implied-volatility surface, after Gatheral (2004).

    Total implied variance as a function of log-moneyness [k = ln(K / F)]:
    [w(k) = a + b * (rho * (k - m) + sqrt ((k - m)^2 + sigma^2))].
    Implied vol is [sqrt (w / T)]. *)

type params =
  { a : float
  ; b : float
  ; rho : float
  ; m : float
  ; sigma : float
  }

(** Total variance [w(k)]. *)
val total_variance : params -> float -> float

(** Implied volatility at log-moneyness [k] for expiry [t] (years). *)
val implied_vol : params -> expiry:float -> float -> float

(** Basic validity: [b >= 0], [|rho| < 1], [sigma > 0], and the minimum of
    total variance [a + b * sigma * sqrt (1 - rho^2)] is non-negative. *)
val is_valid : params -> bool

(** Butterfly-arbitrage check (Gatheral): the implied density
    [g(k) = (1 - k w'/(2w))^2 - (w'^2/4)(1/w + 1/4) + w''/2] must be
    non-negative. Returns the minimum of [g] over [k_lo, k_hi] sampled on a
    grid; a negative value means the slice admits arbitrage. *)
val min_butterfly_density : params -> k_lo:float -> k_hi:float -> float

type point =
  { k : float  (** log-moneyness *)
  ; w : float  (** observed total variance, [vol^2 * T] *)
  }

(** Least-squares fit by Nelder-Mead with several restarts, with the
    constraints enforced by a smooth reparameterisation. Returns the fitted
    parameters and the root-mean-square error in total variance.
    @raise Invalid_argument with fewer than 5 points. *)
val fit : point list -> params * float
