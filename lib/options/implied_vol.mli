(** Implied volatility from an option price.

    Newton's method on vega, safeguarded by a bracketing interval: whenever a
    Newton step would leave the bracket (typically when vega is tiny, deep in
    or out of the money) the method bisects instead. So it always converges
    when a solution exists. *)

type error =
  | Below_intrinsic  (** price is under the no-arbitrage lower bound *)
  | Above_upper_bound  (** price exceeds the no-arbitrage upper bound *)
  | No_time_value  (** zero expiry: any vol gives the same price *)
  | Not_converged

val error_to_string : error -> string

(** [solve kind ~price ~spot ~strike ~rate ~expiry] returns the volatility
    that makes {!Bs.price} equal [price], to within [tol] (default 1e-10) in
    price. *)
val solve
  :  ?tol:float
  -> Bs.kind
  -> price:float
  -> spot:float
  -> strike:float
  -> rate:float
  -> expiry:float
  -> (float, error) result
