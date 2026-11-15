open Core_types

type config =
  { sim : Sim.config
  ; stock_vol : float
  ; factor_share : float
  ; basket : Basket.constituent list
  ; quoter : Mm.Quoter.params
  ; nav_weight : float
  }

type result =
  { total_pnl : float
  ; attribution : Mm.Backtest.attribution
  ; volume : int
  ; fills : int
  ; max_abs_inventory : int
  ; nav_tracking_error : float
  }

(* Prices here are in the same ticks as the ETF book: 1 tick = 1/ticks_per_unit.
   Stock prices and weights are in currency units, and the NAV is converted to
   ticks when it feeds the ETF book. *)
let ticks_per_unit = float_of_int Price.ticks_per_unit

let default_basket =
  [ { Basket.name = "AAA"; weight = 2.; price = 50.; half_spread = 0.01 }
  ; { name = "BBB"; weight = 1.; price = 30.; half_spread = 0.02 }
  ; { name = "CCC"; weight = 4.; price = 10.; half_spread = 0.005 }
  ]
;;

let default_config =
  { sim =
      { Sim.default_config with
        n_events = 20_000
      ; start_mid = Price.of_ticks 17_000 (* NAV 170.00 *)
      ; informed_prob = 0.4
      ; news_lag_events = 400.
      }
  ; stock_vol = 0.013 (* NAV volatility about 8 ticks per sqrt(second) *)
  ; factor_share = 0.6
  ; basket = default_basket
  ; quoter =
      { Mm.Quoter.model =
          Mm.Quoter.Avellaneda_stoikov { gamma = 0.02; sigma = 3.; k = 1.5; horizon_s = 1. }
      ; qty = Qty.of_int 5
      ; max_inventory = 50
      }
  ; nav_weight = 0.
  }
;;

let validate cfg =
  if cfg.basket = [] then invalid_arg "Etf_market.run: empty basket";
  if not (cfg.nav_weight >= 0. && cfg.nav_weight <= 1.)
  then invalid_arg "Etf_market.run: nav_weight must be in [0, 1]";
  if not (cfg.factor_share >= 0. && cfg.factor_share <= 1.)
  then invalid_arg "Etf_market.run: factor_share must be in [0, 1]";
  if cfg.sim.n_events <= 0 then invalid_arg "Etf_market.run: n_events must be positive"
;;

let remove_all book ids =
  List.fold_left
    (fun b id ->
      match Book.cancel b id with
      | Some (b, _) -> b
      | None -> b)
    book
    ids
;;

let run cfg =
  validate cfg;
  let n = cfg.sim.n_events in
  (* Separate generators, so changing the market maker never changes the stocks
     or the order flow: both makers face exactly the same world. *)
  let stock_rng = Random.State.make [| cfg.sim.seed; 1 |] in
  let flow = Sim.Flow.create cfg.sim in
  let ids = Sim.Flow.ids flow in
  let prices = Array.of_list (List.map (fun (c : Basket.constituent) -> c.price) cfg.basket) in
  let weights = Array.of_list (List.map (fun (c : Basket.constituent) -> c.weight) cfg.basket) in
  let nav () =
    let s = ref 0. in
    Array.iteri (fun i p -> s := !s +. (weights.(i) *. p)) prices;
    !s
  in
  let loading = sqrt cfg.factor_share and idio = sqrt (1. -. cfg.factor_share) in
  let start_mid = nav () *. ticks_per_unit in
  let mids = Array.make n start_mid in
  let inventory_path = Array.make n 0 in
  let pnl_path = Array.make n 0. in
  let fills = ref [] in
  let inventory = ref 0 and cash = ref 0. in
  let mine = ref [] in
  let last_mid = ref start_mid in
  let track_sq = ref 0. and track_n = ref 0 in
  let mean_gap_s = 1. /. cfg.sim.arrival_rate_per_s in
  let place book side price =
    let id = Order_id.Gen.next ids in
    let order : Book.order =
      { id; side; price = Price.of_ticks price; qty = cfg.quoter.qty }
    in
    let book, trades = Book.add book order ~rest:true in
    if trades <> [] then failwith "Etf_market: post-only quote traded on entry";
    mine := id :: !mine;
    book
  in
  let rec loop step book =
    (* Stocks move first: one common shock plus an idiosyncratic one each. *)
    let dt = mean_gap_s in
    let factor = Options.Normal.sample stock_rng in
    Array.iteri
      (fun i p ->
        let shock = (loading *. factor) +. (idio *. Options.Normal.sample stock_rng) in
        prices.(i) <- Float.max 0.01 (p +. (cfg.stock_vol *. sqrt dt *. shock)))
      prices;
    let nav_ticks = nav () *. ticks_per_unit in
    match Sim.Flow.next ~fundamental:nav_ticks flow ~book with
    | None -> ()
    | Some event ->
      let book, trades = Sim.apply book event in
      List.iter
        (fun (t : Book.trade) ->
          if List.exists (Order_id.equal t.maker) !mine
          then (
            let side = Side.opposite t.taker_side in
            let qty = Qty.to_int t.qty and price = Price.to_ticks t.price in
            inventory := !inventory + (Side.sign side * qty);
            cash := !cash -. float_of_int (Side.sign side * qty * price);
            fills := { Mm.Backtest.step; time_us = event.time_us; side; price; qty } :: !fills))
        trades;
      let market_book = remove_all book !mine in
      (match Book.mid market_book with
       | Some m ->
         last_mid := m;
         track_sq := !track_sq +. ((m -. nav_ticks) ** 2.);
         incr track_n
       | None -> ());
      mids.(step) <- !last_mid;
      mine := [];
      let book =
        match Book.mid market_book with
        | None -> market_book
        | Some book_mid ->
          (* The reference price: the book's own mid, blended toward the NAV
             that is computed from the observable stock prices. *)
          let reference = ((1. -. cfg.nav_weight) *. book_mid) +. (cfg.nav_weight *. nav_ticks) in
          let best_ticks = Option.map (fun (p, _) -> Price.to_ticks p) in
          let bid, ask =
            Mm.Quoter.quotes
              cfg.quoter
              ~mid:reference
              ~inventory:!inventory
              ~best_bid:(best_ticks (Book.best_bid market_book))
              ~best_ask:(best_ticks (Book.best_ask market_book))
          in
          let b = market_book in
          let b = match bid with Some p -> place b Side.Buy p | None -> b in
          (match ask with Some p -> place b Side.Sell p | None -> b)
      in
      inventory_path.(step) <- !inventory;
      pnl_path.(step) <- !cash +. (float_of_int !inventory *. !last_mid);
      loop (step + 1) book
  in
  loop 0 Book.empty;
  let fills = List.rev !fills in
  let attribution = Mm.Backtest.attribute ~start_mid ~mids ~markout:100 fills in
  { total_pnl = pnl_path.(n - 1)
  ; attribution
  ; volume = List.fold_left (fun a (f : Mm.Backtest.fill) -> a + f.qty) 0 fills
  ; fills = List.length fills
  ; max_abs_inventory = Array.fold_left (fun m q -> max m (abs q)) 0 inventory_path
  ; nav_tracking_error = (if !track_n = 0 then Float.nan else sqrt (!track_sq /. float_of_int !track_n))
  }
;;

(* ---- tests ---- *)

let small = { default_config with sim = { default_config.sim with n_events = 4_000 } }

let%test "the three PnL components sum to the total" =
  List.for_all
    (fun w ->
      let r = run { small with nav_weight = w } in
      let a = r.attribution in
      Float.abs (a.spread_capture +. a.adverse_selection +. a.inventory -. r.total_pnl)
      < 1e-6 *. (1. +. Float.abs r.total_pnl))
    [ 0.; 0.5; 1. ]
;;

let%test "the run is deterministic" = run small = run small

let%test "both makers face the same world: tracking error does not depend on the maker" =
  (* The ETF book is also shaped by the maker's own quotes, so the figures are
     close rather than identical; but the stock paths and order flow are shared,
     so they must be within a few percent of each other. *)
  let a = (run { small with nav_weight = 0. }).nav_tracking_error in
  let b = (run { small with nav_weight = 1. }).nav_tracking_error in
  Float.abs (a -. b) < 0.1 *. a
;;

let%test "the maker trades and respects its inventory limit" =
  let r = run small in
  r.fills > 0
  && r.volume > 0
  && r.max_abs_inventory <= small.quoter.max_inventory + Qty.to_int small.quoter.qty
;;

let%test "bad configurations are rejected" =
  let bad c = try ignore (run c); false with Invalid_argument _ -> true in
  bad { small with nav_weight = 1.5 }
  && bad { small with nav_weight = -0.1 }
  && bad { small with factor_share = 2. }
  && bad { small with basket = [] }
;;

let%test "a NAV-only maker protects against adverse selection when informed flow is heavy" =
  (* The mechanism, not the total: averaged over seeds, anchoring to NAV makes
     the adverse-selection component better than quoting around the book's own
     mid. Paired by seed so both makers see the same world. *)
  let seeds = [ 1; 2; 3; 4; 5; 6 ] in
  let adverse w =
    List.fold_left
      (fun acc seed ->
        let r =
          run { small with nav_weight = w; sim = { small.sim with seed; informed_prob = 0.6 } }
        in
        acc +. r.attribution.adverse_selection)
      0.
      seeds
  in
  adverse 1. > adverse 0.
;;

(* A sanity bound on scale. If the stock and ETF units disagree (the bug that
   produced a 3,700-tick gap and million-tick PnLs), the ETF book no longer
   follows the NAV and this fails. Measured: about 4.7 ticks for the default
   configuration; the bound leaves room but is far below any unit error. *)
let%test "the ETF book tracks the NAV to within a few ticks" =
  List.for_all
    (fun w ->
      let r = run { small with nav_weight = w } in
      r.nav_tracking_error > 0. && r.nav_tracking_error < 25.)
    [ 0.; 0.5; 1. ]
;;

(* The basket's starting NAV and the ETF's starting mid must agree, in ticks. *)
let%test "the default basket's NAV matches the ETF's starting mid" =
  Float.abs
    ((Basket.nav default_config.basket *. ticks_per_unit)
     -. float_of_int (Price.to_ticks default_config.sim.start_mid))
  < 1e-6
;;
