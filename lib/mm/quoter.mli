(** Quote-placement rules for a single-instrument market maker.

    Prices are in ticks. [Avellaneda_stoikov] follows Avellaneda and Stoikov,
    "High-frequency trading in a limit order book" (2008), in the stationary
    form where the remaining horizon is a constant [horizon_s]:

    - reservation price [r = mid - q * gamma * sigma^2 * horizon_s]
    - total spread [delta = gamma * sigma^2 * horizon_s
                            + (2 / gamma) * ln (1 + gamma / k)]
    - bid [r - delta/2], ask [r + delta/2]

    [q] is signed inventory, [sigma] the mid-price volatility in ticks per
    sqrt(second), and [k] the decay of order-arrival intensity with distance
    from mid. A larger [gamma] means stronger inventory aversion. *)

open Core_types

type model =
  | Avellaneda_stoikov of
      { gamma : float
      ; sigma : float
      ; k : float
      ; horizon_s : float
      }
  | Fixed of { half_spread_ticks : float }
      (** Symmetric quotes around mid, no inventory skew. A baseline. *)

type params =
  { model : model
  ; qty : Qty.t  (** size quoted on each side *)
  ; max_inventory : int  (** stop quoting the side that would grow |inventory| past this *)
  }

(** Reservation price in ticks. Equal to [mid] for [Fixed]. *)
val reservation_price : model -> mid:float -> inventory:int -> float

(** Full quoted spread in ticks. *)
val spread : model -> float

(** [quotes params ~mid ~inventory ~best_bid ~best_ask] returns
    [(bid, ask)] as integer tick prices. [best_bid] and [best_ask] are the
    market's own best prices {e excluding} our quotes; quotes are clamped so
    they never cross them (post-only). A side is [None] when the inventory
    limit forbids it. Whenever both sides are quoted, [bid < ask]. *)
val quotes
  :  params
  -> mid:float
  -> inventory:int
  -> best_bid:int option
  -> best_ask:int option
  -> int option * int option
