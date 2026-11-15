(** Least-squares hedge of an ETF with a subset of its constituents.

    You often cannot (or do not want to) trade every name in the basket. Given
    return histories for the ETF and for [m] hedge instruments, find the
    positions [h] that minimise the variance of the hedged return
    [r_etf - sum_i h_i * r_i]. This is ordinary least squares without an
    intercept, solved from the normal equations [(X'X) h = X'y] by Gaussian
    elimination with partial pivoting. *)

type result =
  { weights : float array  (** [h], one per hedge instrument *)
  ; residual_std : float  (** standard deviation of the hedged return *)
  ; unhedged_std : float  (** standard deviation of the raw ETF return *)
  ; r_squared : float  (** share of ETF return variance removed *)
  }

(** [fit ~etf ~hedges] where [etf] has [n] observations and [hedges] is an
    array of [m] series of length [n].
    @raise Invalid_argument on shape mismatch, [n <= m], [m = 0], or a
    singular system (perfectly collinear hedge instruments). *)
val fit : etf:float array -> hedges:float array array -> result
