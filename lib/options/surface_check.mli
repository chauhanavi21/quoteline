(** Static no-arbitrage checks across the expiries of a fitted surface.

    Each expiry is fitted on its own ({!Svi.fit}), which guarantees nothing
    about how the slices relate to each other. Two slices can each be free of
    butterfly arbitrage and still admit a calendar-spread arbitrage.

    {b Calendar condition.} Total implied variance [w(k, T) = vol^2 * T] must be
    non-decreasing in [T] at every fixed log-moneyness [k] (forward moneyness).
    If a later expiry carries {e less} total variance than an earlier one at
    some [k], a calendar spread there has a guaranteed non-negative payoff and a
    negative cost.

    This checks the condition on a grid of [k]; it is a necessary condition
    sampled at finite points, not a proof of the absence of arbitrage between
    the points. *)

type slice =
  { expiry : float  (** in years *)
  ; params : Svi.params
  }

type violation =
  { k : float  (** log-moneyness where it happens *)
  ; earlier : float  (** earlier expiry *)
  ; later : float  (** later expiry *)
  ; w_earlier : float
  ; w_later : float
  ; shortfall : float  (** [w_earlier - w_later], positive *)
  }

(** All grid points where a later slice has less total variance than an
    earlier one. Slices are sorted by expiry first. [tol] (default [1e-9])
    absorbs floating-point noise.
    @raise Invalid_argument with fewer than two slices or a bad grid. *)
val calendar_violations
  :  ?tol:float
  -> slice list
  -> k_lo:float
  -> k_hi:float
  -> n:int
  -> violation list

(** The largest shortfall found, or [0.] when the surface passes. *)
val worst_shortfall : violation list -> float
