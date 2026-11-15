(** Deterministic event-driven market simulator.

    Background order flow (limit orders, marketable orders and cancels) is
    generated from a seeded PRNG and fed through {!Book}. The same seed always
    produces the same event log, so every experiment is replayable. All data
    is synthetic. *)

open Core_types

type action =
  | Limit of
      { side : Side.t
      ; price : Price.t
      ; qty : Qty.t
      }
  | Market of
      { side : Side.t
      ; qty : Qty.t
      }
  | Cancel of Order_id.t

type event =
  { time_us : int  (** microseconds since start *)
  ; id : Order_id.t  (** id of the order this event creates or cancels *)
  ; action : action
  }

type config =
  { seed : int
  ; n_events : int
  ; start_mid : Price.t
  ; arrival_rate_per_s : float  (** mean Poisson event rate *)
  ; cancel_prob : float
  ; market_prob : float
  ; mean_offset_ticks : float  (** mean distance of limit orders from mid *)
  ; mean_qty : float
  }

val default_config : config

(** Result of applying one event to the book. *)
type step =
  { event : event
  ; trades : Book.trade list
  ; book : Book.t
  }

(** Generate and apply the whole stream, in order. *)
val run : config -> step list

(** CSV: [time_us,id,kind,side,price_ticks,qty]. One line per event. *)
val event_to_csv : event -> string

(** CSV: [time_us,taker,maker,side,price_ticks,qty]. One line per trade. *)
val trade_to_csv : time_us:int -> Book.trade -> string
