(** Persistent limit order book with price-time priority.

    The book is an immutable value: every operation returns a new book, which
    makes replay, property testing and "what if" analysis straightforward. *)

open Core_types

type order =
  { id : Order_id.t
  ; side : Side.t
  ; price : Price.t
  ; qty : Qty.t  (** remaining quantity *)
  }

type trade =
  { taker : Order_id.t
  ; maker : Order_id.t
  ; taker_side : Side.t
  ; price : Price.t  (** always the resting (maker) order's price *)
  ; qty : Qty.t
  }

type t

val empty : t

(** [add t order ~rest] matches [order] against the opposite side, oldest
    resting order first within each price level, best price first. Trades
    execute at the resting order's price. If [rest] is true any unfilled
    remainder joins the book; otherwise it is discarded (IOC semantics).
    Trades are returned in execution order.

    @raise Invalid_argument if [order.id] is already resting in the book. *)
val add : t -> order -> rest:bool -> t * trade list

(** Remove a resting order. [None] if the id is not in the book. *)
val cancel : t -> Order_id.t -> (t * order) option

val find : t -> Order_id.t -> order option
val best_bid : t -> (Price.t * Qty.t) option
val best_ask : t -> (Price.t * Qty.t) option

(** Midpoint of best bid and best ask, in ticks (may end in .5). [None] if
    either side is empty. *)
val mid : t -> float option

(** Total resting quantity on one side. *)
val total_qty : t -> Side.t -> Qty.t

(** Number of resting orders. *)
val order_count : t -> int

(** Aggregated levels, best price first: [(price, total qty)]. *)
val levels : t -> Side.t -> (Price.t * Qty.t) list

(** Structural invariants, for tests: the book is never crossed, no empty
    levels or zero-quantity orders exist, and the id index agrees with the
    levels. Returns [Error reason] on the first violation. *)
val check_invariants : t -> (unit, string) result
