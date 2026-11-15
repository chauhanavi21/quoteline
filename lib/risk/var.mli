(** Value-at-risk and expected shortfall from a sample of profit-and-loss
    outcomes. Losses are reported as positive numbers.

    Convention: at confidence [c] (say 0.99), VaR is the loss exceeded in a
    fraction [1 - c] of outcomes, and expected shortfall (ES) is the mean loss
    over those worst outcomes. Both use the empirical distribution, so with [n]
    samples the tail holds [ceil (n * (1 - c))] outcomes. *)

(** @raise Invalid_argument on an empty sample or [c] outside (0, 1). *)
val var : confidence:float -> float array -> float

(** @raise Invalid_argument on an empty sample or [c] outside (0, 1). *)
val expected_shortfall : confidence:float -> float array -> float

(** Closed-form normal VaR for comparison: [-mean + z * std] with
    [z = inv_cdf confidence]. *)
val normal_var : confidence:float -> mean:float -> std:float -> float

(** Closed-form normal ES: [-mean + std * pdf z / (1 - confidence)]. *)
val normal_es : confidence:float -> mean:float -> std:float -> float
