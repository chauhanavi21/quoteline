(** Standard normal distribution. *)

val pdf : float -> float
val cdf : float -> float

(** Inverse CDF by bisection (accurate to about 1e-12).
    @raise Invalid_argument unless [0 < p < 1]. *)
val inv_cdf : float -> float
