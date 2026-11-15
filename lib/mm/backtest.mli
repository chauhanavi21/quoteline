(** Backtest a market maker against the simulated order flow.

    The maker shares the book with the background flow. After every
    [requote_every] events it cancels its quotes and places fresh post-only
    quotes around the {e market} mid (the mid of the book with its own quotes
    removed). Fills are exact: the maker is just another resting order in
    {!Book}. There is no latency, no fees and no queue-position model; see the
    README for what that means for the results.

    All money is in ticks (1 tick = 0.01). *)

open Core_types

type config =
  { sim : Sim.config
  ; quoter : Quoter.params
  ; requote_every : int  (** events between requotes; 1 = every event *)
  ; markout_events : int  (** horizon, in events, for the adverse-selection split *)
  }

type fill =
  { step : int  (** index of the event that caused the fill *)
  ; time_us : int
  ; side : Side.t  (** our side: [Buy] means we bought *)
  ; price : int
  ; qty : int
  }

(** Exact decomposition of total PnL. For a fill of signed size [s*q] at price
    [p], with [m] the market mid just before the fill, [m_h] the mid
    [markout_events] later and [M] the final mid:
    [s*q*(M - p) = s*q*(m - p) + s*q*(m_h - m) + s*q*(M - m_h)]. *)
type attribution =
  { spread_capture : float  (** edge earned versus mid at the moment of the fill *)
  ; adverse_selection : float  (** mid move over the markout horizon, signed by our side *)
  ; inventory : float  (** mid move from the horizon to the end, signed by our side *)
  }

type result =
  { fills : fill list  (** chronological *)
  ; mids : float array  (** market mid after each event *)
  ; inventory_path : int array
  ; pnl_path : float array  (** mark-to-market PnL after each event *)
  ; final_inventory : int
  ; total_pnl : float  (** cash plus final inventory marked at the final mid *)
  ; attribution : attribution
  ; volume : int  (** total quantity we traded *)
  }

(** The exact PnL decomposition used by {!run}, for any list of fills against a
    series of market mids. [mids.(i)] is the market mid after event [i];
    [start_mid] is the mid before event 0; [markout] is the horizon in events.
    Exposed so other simulations (for example the ETF market) reuse one
    implementation instead of copying it. *)
val attribute
  :  start_mid:float
  -> mids:float array
  -> markout:int
  -> fill list
  -> attribution

(** @raise Invalid_argument if [sim.n_events <= 0], [requote_every <= 0] or
    [markout_events < 0]. *)
val run : config -> result

(** Sample standard deviation of the per-event PnL increments, in ticks. *)
val pnl_step_std : result -> float

(** CSV: [step,mid,inventory,pnl]. One line per event; [step] is the event
    index, which joins to the line number in [events.csv]. *)
val pnl_csv : result -> string list

(** CSV: [step,time_us,side,price_ticks,qty]. *)
val fills_csv : result -> string list
