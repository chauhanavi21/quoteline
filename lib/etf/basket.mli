(** ETF basket valuation and creation/redemption arbitrage.

    An ETF share is a claim on a basket of stocks. Its net asset value (NAV)
    is the basket's value per share. An authorised participant can create new
    ETF shares by delivering the basket, or redeem them to get the basket
    back, so the ETF price is held near NAV. When it drifts further than the
    cost of trading and of the creation/redemption itself, there is a
    risk-free trade:

    - {b premium} ([etf > nav + cost]): sell the ETF, buy the basket, deliver
      the basket to create new ETF shares to cover the short;
    - {b discount} ([etf < nav - cost]): buy the ETF, sell the basket short,
      redeem the ETF for the basket to cover.

    Prices are plain floats in currency units. *)

type constituent =
  { name : string
  ; weight : float  (** shares of this stock in one ETF share *)
  ; price : float
  ; half_spread : float  (** cost to cross the spread on this stock, per share *)
  }

(** NAV per ETF share: [sum weight * price]. *)
val nav : constituent list -> float

type costs =
  { etf_half_spread : float  (** cost to cross the ETF's spread, per share *)
  ; creation_fee : float  (** fixed fee per ETF share created or redeemed *)
  ; borrow_rate : float
        (** annualised cost of borrowing stock on the short leg, as a fraction *)
  ; holding_days : float  (** days until the creation or redemption settles *)
  }

(** All-in cost per ETF share of one round trip: both legs' spreads, the
    creation fee, and borrow for [holding_days]. *)
val round_trip_cost : constituent list -> etf_price:float -> costs -> float

type direction =
  | Sell_etf_buy_basket  (** ETF trades at a premium *)
  | Buy_etf_sell_basket  (** ETF trades at a discount *)

type signal =
  { direction : direction
  ; gross_edge : float  (** [|etf - nav|] per ETF share *)
  ; cost : float
  ; net_edge : float  (** [gross_edge - cost]; positive means profitable *)
  }

(** [None] when the gap does not cover costs, otherwise the profitable
    direction. The edge is {e per ETF share}. *)
val signal : constituent list -> etf_price:float -> costs -> signal option

(** [pnl signal ~shares] is the locked-in profit of doing the trade on
    [shares] ETF shares: [net_edge * shares]. *)
val pnl : signal -> shares:float -> float
