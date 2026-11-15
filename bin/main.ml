(* quoteline CLI.

     quoteline run-sim [--seed N] [--events N] [--out DIR]
     quoteline export  [--seed N] [--events N] [--out DIR]

   [run-sim] writes DIR/events.csv and DIR/trades.csv. [export] writes the JSON
   data files the UI reads. Same seed, same bytes. *)

open Core_types
module J = Export.Json

let usage () =
  prerr_endline
    "usage: quoteline run-sim [--seed N] [--events N] [--out DIR]\n\
    \       quoteline export  [--seed N] [--events N] [--out DIR]";
  exit 2
;;

type args =
  { seed : int
  ; events : int
  ; out : string
  }

let rec parse a = function
  | [] -> a
  | "--seed" :: v :: rest -> parse { a with seed = int_of_string v } rest
  | "--events" :: v :: rest -> parse { a with events = int_of_string v } rest
  | "--out" :: v :: rest -> parse { a with out = v } rest
  | _ -> usage ()
;;

let ensure_dir d = if not (Sys.file_exists d) then Sys.mkdir d 0o755

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc
;;

(* ---- run-sim ---- *)

let run_sim args =
  let a = parse { seed = 42; events = 10_000; out = "out" } args in
  ensure_dir a.out;
  let steps = Sim.run { Sim.default_config with seed = a.seed; n_events = a.events } in
  let lines ls = String.concat "" (List.map (fun l -> l ^ "\n") ls) in
  write_file
    (Filename.concat a.out "events.csv")
    ("time_us,id,kind,side,price_ticks,qty\n"
     ^ lines (List.map (fun (s : Sim.step) -> Sim.event_to_csv s.event) steps));
  let trade_lines =
    List.concat_map
      (fun (s : Sim.step) -> List.map (Sim.trade_to_csv ~time_us:s.event.time_us) s.trades)
      steps
  in
  write_file
    (Filename.concat a.out "trades.csv")
    ("time_us,taker,maker,taker_side,price_ticks,qty\n" ^ lines trade_lines);
  Printf.printf
    "seed=%d events=%d trades=%d -> %s\n"
    a.seed
    (List.length steps)
    (List.length trade_lines)
    a.out
;;

(* ---- export helpers ---- *)

(* Keep about [max_points] evenly spaced entries so the UI never has to chart
   a six-figure series. Always keeps the first and the last element. *)
let thin ~max_points arr =
  let n = Array.length arr in
  if n <= max_points
  then arr
  else (
    let stride = (n + max_points - 1) / max_points in
    let kept = List.filteri (fun i _ -> i mod stride = 0 || i = n - 1) (Array.to_list arr) in
    Array.of_list kept)
;;

let ticks_to_price t = t /. float_of_int Price.ticks_per_unit

let as_params ~gamma =
  { Mm.Quoter.model =
      Mm.Quoter.Avellaneda_stoikov { gamma; sigma = 3.; k = 1.5; horizon_s = 1. }
  ; qty = Qty.of_int 5
  ; max_inventory = 50
  }
;;

let mm_config ~seed ~events ~informed ~vol ~gamma : Mm.Backtest.config =
  { sim =
      { Sim.default_config with
        seed
      ; n_events = events
      ; informed_prob = informed
      ; fundamental_vol = vol
      }
  ; quoter = as_params ~gamma
  ; requote_every = 1
  ; markout_events = 100
  }
;;

(* All money values in the exported files are in currency units, not ticks. *)
let summary_json (r : Mm.Backtest.result) =
  let a = r.attribution in
  J.Object
    [ "total_pnl", J.Float (ticks_to_price r.total_pnl)
    ; "spread_capture", J.Float (ticks_to_price a.spread_capture)
    ; "adverse_selection", J.Float (ticks_to_price a.adverse_selection)
    ; "inventory", J.Float (ticks_to_price a.inventory)
    ; "final_inventory", J.Int r.final_inventory
    ; "volume", J.Int r.volume
    ; "fills", J.Int (List.length r.fills)
    ; "pnl_step_std", J.Float (ticks_to_price (Mm.Backtest.pnl_step_std r))
    ]
;;

(* ---- export: market-maker backtest and sweeps ---- *)

let backtest_json ~seed ~events =
  let r = Mm.Backtest.run (mm_config ~seed ~events ~informed:0.3 ~vol:10. ~gamma:0.02) in
  let mids = thin ~max_points:600 (Array.map ticks_to_price r.mids) in
  let inv = thin ~max_points:600 (Array.map float_of_int r.inventory_path) in
  let pnl = thin ~max_points:600 (Array.map ticks_to_price r.pnl_path) in
  J.Object
    [ "seed", J.Int seed
    ; "events", J.Int events
    ; "unit", J.String "currency units (1 tick = 0.01)"
    ; "summary", summary_json r
    ; "mid", J.floats mids
    ; "inventory", J.floats inv
    ; "pnl", J.floats pnl
    ]
;;

(* How the maker fares as informed flow grows: per-lot attribution averaged
   over several seeds, so the picture is not one lucky path. *)
let informed_sweep_json ~events =
  let seeds = [ 1; 2; 3; 4 ] in
  let rows =
    List.map
      (fun informed ->
        let rs =
          List.map
            (fun seed ->
              Mm.Backtest.run (mm_config ~seed ~events ~informed ~vol:25. ~gamma:0.02))
            seeds
        in
        let vol = List.fold_left (fun a (r : Mm.Backtest.result) -> a + r.volume) 0 rs in
        let sum f = List.fold_left (fun a (r : Mm.Backtest.result) -> a +. f r) 0. rs in
        let per_lot f =
          if vol = 0 then Float.nan else ticks_to_price (sum f) /. float_of_int vol
        in
        J.Object
          [ "informed", J.Float informed
          ; "volume", J.Int vol
          ; "spread_capture", J.Float (per_lot (fun r -> r.attribution.spread_capture))
          ; "adverse_selection", J.Float (per_lot (fun r -> r.attribution.adverse_selection))
          ; "total", J.Float (per_lot (fun r -> r.total_pnl))
          ])
      [ 0.; 0.2; 0.4; 0.6; 0.8; 1. ]
  in
  J.Object [ "seeds", J.Int (List.length seeds); "unit", J.String "currency units per lot traded"; "rows", J.List rows ]
;;

let gamma_sweep_json ~events =
  let rows =
    List.map
      (fun gamma ->
        let r =
          Mm.Backtest.run (mm_config ~seed:7 ~events ~informed:0.3 ~vol:10. ~gamma)
        in
        let max_inv = Array.fold_left (fun m q -> max m (abs q)) 0 r.inventory_path in
        J.Object
          [ "gamma", J.Float gamma
          ; "total_pnl", J.Float (ticks_to_price r.total_pnl)
          ; "pnl_step_std", J.Float (ticks_to_price (Mm.Backtest.pnl_step_std r))
          ; "max_abs_inventory", J.Int max_inv
          ; "volume", J.Int r.volume
          ])
      [ 0.001; 0.005; 0.02; 0.1; 0.5 ]
  in
  J.Object [ "rows", J.List rows ]
;;

(* ---- export: options ---- *)

let surface_json () =
  let spot = 100. and rate = 0.03 in
  (* A smile with skew, as SVI parameters per expiry; prices come from there. *)
  let true_slice t =
    { Options.Svi.a = 0.01 *. t
    ; b = 0.08 *. sqrt t
    ; rho = -0.45
    ; m = 0.02
    ; sigma = 0.15 +. (0.1 *. t)
    }
  in
  let expiries = [ 0.1; 0.25; 0.5; 1.0 ] in
  let strikes = List.init 11 (fun i -> 70. +. (6. *. float_of_int i)) in
  let rng = Random.State.make [| 5 |] in
  let slices =
    List.map
      (fun t ->
        let p = true_slice t in
        let fwd = spot *. exp (rate *. t) in
        let quotes =
          List.map
            (fun strike ->
              let k = log (strike /. fwd) in
              let vol = Options.Svi.implied_vol p ~expiry:t k in
              (* Round-trip through a price, as a real quote would be, and add
                 0.5% noise to the price so the fit has something to do. *)
              let kind = if strike >= fwd then Options.Bs.Call else Options.Bs.Put in
              let clean = Options.Bs.price kind ~spot ~strike ~rate ~vol ~expiry:t in
              let price = clean *. (1. +. (0.005 *. ((Random.State.float rng 2.) -. 1.))) in
              match
                Options.Implied_vol.solve kind ~price ~spot ~strike ~rate ~expiry:t
              with
              | Ok iv -> Some (strike, k, iv)
              | Error _ -> None)
            strikes
          |> List.filter_map Fun.id
        in
        let points = List.map (fun (_, k, iv) -> { Options.Svi.k; w = iv *. iv *. t }) quotes in
        let fit, rmse = Options.Svi.fit points in
        let k_lo = log (70. /. fwd) and k_hi = log (130. /. fwd) in
        let butterfly = Options.Svi.min_butterfly_density fit ~k_lo ~k_hi in
        let curve =
          List.init 41 (fun i ->
            let k = k_lo +. ((k_hi -. k_lo) *. float_of_int i /. 40.) in
            J.Object
              [ "strike", J.Float (fwd *. exp k)
              ; "vol", J.Float (Options.Svi.implied_vol fit ~expiry:t k)
              ])
        in
        J.Object
          [ "expiry", J.Float t
          ; "forward", J.Float fwd
          ; ( "quotes"
            , J.List
                (List.map
                   (fun (strike, _, iv) ->
                     J.Object [ "strike", J.Float strike; "vol", J.Float iv ])
                   quotes) )
          ; "fit", J.List curve
          ; "fit_rmse_variance", J.Float rmse
          ; "min_butterfly_density", J.Float butterfly
          ; ( "params"
            , J.Object
                [ "a", J.Float fit.a
                ; "b", J.Float fit.b
                ; "rho", J.Float fit.rho
                ; "m", J.Float fit.m
                ; "sigma", J.Float fit.sigma
                ] )
          ])
      expiries
  in
  J.Object [ "spot", J.Float spot; "rate", J.Float rate; "slices", J.List slices ]
;;

let hedging_json () =
  let cfg steps real_vol : Options.Hedge.config =
    { kind = Options.Bs.Call
    ; spot = 100.
    ; strike = 100.
    ; rate = 0.05
    ; drift = 0.05
    ; implied_vol = 0.2
    ; real_vol
    ; expiry = 1.
    ; steps
    }
  in
  let scaling =
    List.map
      (fun steps ->
        let s = Options.Hedge.summarise (cfg steps 0.2) ~seed:1 ~paths:2000 in
        J.Object
          [ "steps", J.Int steps
          ; "mean_pnl", J.Float s.mean_pnl
          ; "std_pnl", J.Float s.std_pnl
          ])
      [ 12; 24; 52; 104; 252; 504 ]
  in
  let mismatch =
    List.map
      (fun rv ->
        let s = Options.Hedge.summarise (cfg 252 rv) ~seed:7 ~paths:1500 in
        J.Object
          [ "real_vol", J.Float rv; "mean_pnl", J.Float s.mean_pnl; "std_pnl", J.Float s.std_pnl ])
      [ 0.1; 0.15; 0.2; 0.25; 0.3; 0.4 ]
  in
  let path = Options.Hedge.simulate (cfg 252 0.3) (Random.State.make [| 11 |]) in
  J.Object
    [ "scaling", J.List scaling
    ; "mismatch", J.List mismatch
    ; ( "example_path"
      , J.Object
          [ "spots", J.floats path.spots
          ; "deltas", J.floats path.deltas
          ; "premium", J.Float path.premium
          ; "pnl", J.Float path.pnl
          ; "pnl_gamma_formula", J.Float path.pnl_gamma_formula
          ] )
    ]
;;

(* ---- export: ETF ---- *)

let etf_json () =
  let basket price_a price_b price_c =
    [ { Etf.Basket.name = "AAA"; weight = 2.; price = price_a; half_spread = 0.01 }
    ; { name = "BBB"; weight = 1.; price = price_b; half_spread = 0.02 }
    ; { name = "CCC"; weight = 4.; price = price_c; half_spread = 0.005 }
    ]
  in
  let costs =
    { Etf.Basket.etf_half_spread = 0.02
    ; creation_fee = 0.05
    ; borrow_rate = 0.0365
    ; holding_days = 2.
    }
  in
  let cs = basket 50. 30. 10. in
  let nav = Etf.Basket.nav cs in
  let cost = Etf.Basket.round_trip_cost cs ~etf_price:nav costs in
  let scan =
    List.init 41 (fun i ->
      let etf_price = nav -. 1. +. (0.05 *. float_of_int i) in
      let net, dir =
        match Etf.Basket.signal cs ~etf_price costs with
        | None -> 0., J.String "none"
        | Some s ->
          ( s.net_edge
          , J.String
              (match s.direction with
               | Etf.Basket.Sell_etf_buy_basket -> "sell_etf_buy_basket"
               | Etf.Basket.Buy_etf_sell_basket -> "buy_etf_sell_basket") )
      in
      J.Object
        [ "etf_price", J.Float etf_price
        ; "gap", J.Float (etf_price -. nav)
        ; "net_edge", J.Float net
        ; "direction", dir
        ])
  in
  (* Hedge-ratio demo: replicate the ETF's returns with only two of its three
     names, on simulated correlated returns. *)
  let rng = Random.State.make [| 13 |] in
  let n = 750 in
  let g () = Options.Normal.sample rng in
  let market = Array.init n (fun _ -> 0.01 *. g ()) in
  let ret beta idio = Array.init n (fun t -> (beta *. market.(t)) +. (idio *. g ())) in
  let ra = ret 1.1 0.004 and rb = ret 0.9 0.006 and rc = ret 1.0 0.005 in
  let etf_ret =
    Array.init n (fun t ->
      ((100. *. ra.(t)) +. (30. *. rb.(t)) +. (40. *. rc.(t))) /. nav)
  in
  let partial = Etf.Hedge_ratio.fit ~etf:etf_ret ~hedges:[| ra; rb |] in
  let full = Etf.Hedge_ratio.fit ~etf:etf_ret ~hedges:[| ra; rb; rc |] in
  let hr (r : Etf.Hedge_ratio.result) =
    J.Object
      [ "weights", J.floats r.weights
      ; "residual_std", J.Float r.residual_std
      ; "unhedged_std", J.Float r.unhedged_std
      ; "r_squared", J.Float r.r_squared
      ]
  in
  J.Object
    [ ( "basket"
      , J.List
          (List.map
             (fun (c : Etf.Basket.constituent) ->
               J.Object
                 [ "name", J.String c.name
                 ; "weight", J.Float c.weight
                 ; "price", J.Float c.price
                 ])
             cs) )
    ; "nav", J.Float nav
    ; "round_trip_cost", J.Float cost
    ; "scan", J.List scan
    ; "hedge_two_of_three", hr partial
    ; "hedge_all_three", hr full
    ]
;;

(* ---- export: risk ---- *)

let risk_json () =
  (* Daily PnL of a short-gamma book, from simulated hedged option paths. *)
  let cfg : Options.Hedge.config =
    { kind = Options.Bs.Call
    ; spot = 100.
    ; strike = 100.
    ; rate = 0.05
    ; drift = 0.05
    ; implied_vol = 0.2
    ; real_vol = 0.3
    ; expiry = 1.
    ; steps = 252
    }
  in
  let rng = Random.State.make [| 17 |] in
  let pnl = Array.init 5000 (fun _ -> (Options.Hedge.simulate cfg rng).pnl) in
  let mean = Array.fold_left ( +. ) 0. pnl /. float_of_int (Array.length pnl) in
  let std =
    sqrt
      (Array.fold_left (fun a x -> a +. ((x -. mean) ** 2.)) 0. pnl
       /. float_of_int (Array.length pnl - 1))
  in
  let level c =
    J.Object
      [ "confidence", J.Float c
      ; "var", J.Float (Risk.Var.var ~confidence:c pnl)
      ; "es", J.Float (Risk.Var.expected_shortfall ~confidence:c pnl)
      ; "normal_var", J.Float (Risk.Var.normal_var ~confidence:c ~mean ~std)
      ; "normal_es", J.Float (Risk.Var.normal_es ~confidence:c ~mean ~std)
      ]
  in
  let lo = Array.fold_left Float.min infinity pnl
  and hi = Array.fold_left Float.max neg_infinity pnl in
  let bins = 40 in
  let width = (hi -. lo) /. float_of_int bins in
  let counts = Array.make bins 0 in
  Array.iter
    (fun x ->
      let b = min (bins - 1) (int_of_float ((x -. lo) /. width)) in
      counts.(b) <- counts.(b) + 1)
    pnl;
  J.Object
    [ "paths", J.Int (Array.length pnl)
    ; "mean", J.Float mean
    ; "std", J.Float std
    ; "levels", J.List (List.map level [ 0.9; 0.95; 0.99 ])
    ; ( "histogram"
      , J.Object
          [ "lo", J.Float lo; "width", J.Float width; "counts", J.ints counts ] )
    ]
;;

let export args =
  let a = parse { seed = 42; events = 20_000; out = "out" } args in
  ensure_dir a.out;
  let emit name json =
    let path = Filename.concat a.out name in
    write_file path (J.to_string json ^ "\n");
    Printf.printf "wrote %s\n%!" path
  in
  emit "backtest.json" (backtest_json ~seed:a.seed ~events:a.events);
  emit "informed_sweep.json" (informed_sweep_json ~events:(a.events / 2));
  emit "gamma_sweep.json" (gamma_sweep_json ~events:a.events);
  emit "surface.json" (surface_json ());
  emit "hedging.json" (hedging_json ());
  emit "etf.json" (etf_json ());
  emit "risk.json" (risk_json ())
;;

let () =
  match Array.to_list Sys.argv with
  | _ :: "run-sim" :: args -> run_sim args
  | _ :: "export" :: args -> export args
  | _ -> usage ()
;;
