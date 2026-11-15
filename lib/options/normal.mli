(** Standard normal distribution. *)

val pdf : float -> float
val cdf : float -> float

(** Inverse CDF by bisection (accurate to about 1e-12).
    @raise Invalid_argument unless [0 < p < 1]. *)
val inv_cdf : float -> float

(** Standard normal variate by Box-Muller. Consumes two uniforms per call, so
    a seeded generator gives a reproducible stream. *)
val sample : Random.State.t -> float
