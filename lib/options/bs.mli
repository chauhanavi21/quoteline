(** Black-Scholes pricing and Greeks for European options on a
    non-dividend-paying underlying. Rates and volatilities are annualised
    decimals (0.05 = 5%); [expiry] is in years.

    At [expiry <= 0] or [vol <= 0] the price is the (discounted-forward)
    intrinsic value, delta is a step function and the other Greeks are 0. *)

type kind =
  | Call
  | Put

val kind_to_string : kind -> string

val price
  :  kind
  -> spot:float
  -> strike:float
  -> rate:float
  -> vol:float
  -> expiry:float
  -> float

type greeks =
  { delta : float
  ; gamma : float
  ; vega : float  (** per 1.00 (100 percentage points) of volatility *)
  ; theta : float  (** per year; divide by 365 or 252 for a daily figure *)
  ; rho : float  (** per 1.00 of the interest rate *)
  }

val greeks
  :  kind
  -> spot:float
  -> strike:float
  -> rate:float
  -> vol:float
  -> expiry:float
  -> greeks
