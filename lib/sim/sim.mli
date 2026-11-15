(** Deterministic event-driven market simulator.

    Background order flow (limit orders, marketable orders and cancels) is
    generated from a seeded PRNG and fed through {!Book}. The same seed always
    produces the same event log, so every experiment is replayable. All data
    is synthetic.

    A latent {e fundamental} price follows a Gaussian random walk. A fraction
    of market orders are {e informed}: they trade toward the fundamental. This
    is what gives a market maker adverse selection to suffer from. Passive
    orders quote around a {e lagged} fundamental, so the book follows the news
    with a delay.

    Calibration matters: informed flow only hurts a market maker when the
    news moved since the book last updated is larger than the maker's
    half-spread. With the default [fundamental_vol] it is not, and informed
    trading barely shows up in a maker's PnL; raise it to see the effect. *)

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
  ; mean_lifetime_events : float
        (** Each limit order expires (is cancelled) after an exponentially
            distributed number of events with this mean. Together with the
            arrival rate this sets the book depth. *)
  ; market_prob : float  (** share of non-cancel events that are market orders *)
  ; mean_offset_ticks : float  (** mean distance of limit orders from mid *)
  ; mean_qty : float
  ; fundamental_vol : float  (** fundamental volatility, ticks per sqrt(second) *)
  ; informed_prob : float  (** share of market orders that are informed *)
  ; news_lag_events : float
        (** Passive orders quote around an exponential moving average of the
            fundamental with this time constant, in events. Larger means
            staler quotes and more adverse selection for resting orders. *)
  }

val default_config : config

(** Apply one event to a book. Market orders are IOC orders priced through
    the whole book. Cancelling an order that is already gone is a no-op. *)
val apply : Book.t -> event -> Book.t * Book.trade list

(** Result of applying one event to the book. *)
type step =
  { event : event
  ; trades : Book.trade list
  ; book : Book.t
  }

(** Generate and apply the whole stream, in order. *)
val run : config -> step list

(** Stateful generator of background flow. Unlike {!run}, it lets a strategy
    act between events: the caller applies each event itself (see {!apply})
    and may add its own orders to the book in between. *)
module Flow : sig
  type t

  val create : config -> t

  (** Id generator shared with the caller, so ids never collide. *)
  val ids : t -> Order_id.Gen.t

  (** Next event given the current book, or [None] after [n_events]. *)
  val next : t -> book:Book.t -> event option

  (** The hidden fundamental price, in ticks. For diagnostics and tests
      only: a strategy that reads this is cheating. *)
  val fundamental : t -> float
end

(** CSV: [time_us,id,kind,side,price_ticks,qty]. One line per event. *)
val event_to_csv : event -> string

(** CSV: [time_us,taker,maker,side,price_ticks,qty]. One line per trade. *)
val trade_to_csv : time_us:int -> Book.trade -> string
