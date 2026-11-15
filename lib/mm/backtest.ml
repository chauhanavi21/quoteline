open Core_types

type config =
  { sim : Sim.config
  ; quoter : Quoter.params
  ; requote_every : int
  ; markout_events : int
  }

type fill =
  { step : int
  ; time_us : int
  ; side : Side.t
  ; price : int
  ; qty : int
  }

type attribution =
  { spread_capture : float
  ; adverse_selection : float
  ; inventory : float
  }

type result =
  { fills : fill list
  ; mids : float array
  ; inventory_path : int array
  ; pnl_path : float array
  ; final_inventory : int
  ; total_pnl : float
  ; attribution : attribution
  ; volume : int
  }

let remove_all book ids =
  List.fold_left
    (fun b id ->
      match Book.cancel b id with
      | Some (b, _) -> b
      | None -> b)
    book
    ids
;;

let attribute ~start_mid ~mids ~markout fills =
  let n = Array.length mids in
  let m_final = mids.(n - 1) in
  List.fold_left
    (fun acc f ->
      let sq = float_of_int (Side.sign f.side * f.qty) in
      let p = float_of_int f.price in
      let m_i = if f.step = 0 then start_mid else mids.(f.step - 1) in
      let m_h = mids.(min (f.step + markout) (n - 1)) in
      { spread_capture = acc.spread_capture +. (sq *. (m_i -. p))
      ; adverse_selection = acc.adverse_selection +. (sq *. (m_h -. m_i))
      ; inventory = acc.inventory +. (sq *. (m_final -. m_h))
      })
    { spread_capture = 0.; adverse_selection = 0.; inventory = 0. }
    fills
;;

let run cfg =
  let n = cfg.sim.n_events in
  if n <= 0 then invalid_arg "Backtest.run: n_events must be positive";
  if cfg.requote_every <= 0 then invalid_arg "Backtest.run: requote_every must be positive";
  if cfg.markout_events < 0 then invalid_arg "Backtest.run: markout_events must be >= 0";
  let flow = Sim.Flow.create cfg.sim in
  let ids = Sim.Flow.ids flow in
  let start_mid = float_of_int (Price.to_ticks cfg.sim.start_mid) in
  let mids = Array.make n start_mid in
  let inventory_path = Array.make n 0 in
  let pnl_path = Array.make n 0. in
  let fills = ref [] in
  let inventory = ref 0 in
  let cash = ref 0. in
  let mine = ref [] in
  let last_mid = ref start_mid in
  let place book side price =
    let id = Order_id.Gen.next ids in
    let order : Book.order =
      { id; side; price = Price.of_ticks price; qty = cfg.quoter.qty }
    in
    let book, trades = Book.add book order ~rest:true in
    if trades <> [] then failwith "Backtest: post-only quote traded on entry";
    mine := id :: !mine;
    book
  in
  let rec loop step book =
    match Sim.Flow.next flow ~book with
    | None -> ()
    | Some event ->
      let book, trades = Sim.apply book event in
      List.iter
        (fun (t : Book.trade) ->
          if List.exists (Order_id.equal t.maker) !mine
          then (
            let side = Side.opposite t.taker_side in
            let qty = Qty.to_int t.qty in
            let price = Price.to_ticks t.price in
            inventory := !inventory + (Side.sign side * qty);
            cash := !cash -. float_of_int (Side.sign side * qty * price);
            fills := { step; time_us = event.time_us; side; price; qty } :: !fills))
        trades;
      (* The market mid is measured with our own quotes taken out. *)
      let market_book = remove_all book !mine in
      (match Book.mid market_book with
       | Some m -> last_mid := m
       | None -> ());
      mids.(step) <- !last_mid;
      let book =
        if step mod cfg.requote_every <> 0
        then book
        else (
          mine := [];
          match Book.mid market_book with
          | None -> market_book (* one-sided market: stand aside *)
          | Some mid ->
            let best_ticks = Option.map (fun (p, _) -> Price.to_ticks p) in
            let bid, ask =
              Quoter.quotes
                cfg.quoter
                ~mid
                ~inventory:!inventory
                ~best_bid:(best_ticks (Book.best_bid market_book))
                ~best_ask:(best_ticks (Book.best_ask market_book))
            in
            let b = market_book in
            let b = match bid with Some p -> place b Side.Buy p | None -> b in
            (match ask with Some p -> place b Side.Sell p | None -> b))
      in
      inventory_path.(step) <- !inventory;
      pnl_path.(step) <- !cash +. (float_of_int !inventory *. !last_mid);
      loop (step + 1) book
  in
  loop 0 Book.empty;
  let fills = List.rev !fills in
  let attribution = attribute ~start_mid ~mids ~markout:cfg.markout_events fills in
  { fills
  ; mids
  ; inventory_path
  ; pnl_path
  ; final_inventory = !inventory
  ; total_pnl = pnl_path.(n - 1)
  ; attribution
  ; volume = List.fold_left (fun a f -> a + f.qty) 0 fills
  }
;;

let pnl_step_std r =
  let n = Array.length r.pnl_path in
  if n < 3
  then 0.
  else (
    let d i = r.pnl_path.(i) -. r.pnl_path.(i - 1) in
    let m = Array.length r.pnl_path - 1 in
    let mean = (r.pnl_path.(n - 1) -. r.pnl_path.(0)) /. float_of_int m in
    let ss = ref 0. in
    for i = 1 to n - 1 do
      ss := !ss +. ((d i -. mean) ** 2.)
    done;
    sqrt (!ss /. float_of_int (m - 1)))
;;

let pnl_csv r =
  let n = Array.length r.pnl_path in
  List.init n (fun i ->
    Printf.sprintf "%d,%.1f,%d,%.1f" i r.mids.(i) r.inventory_path.(i) r.pnl_path.(i))
;;

let fills_csv r =
  List.map
    (fun f ->
      Printf.sprintf "%d,%d,%s,%d,%d" f.step f.time_us (Side.to_string f.side) f.price f.qty)
    r.fills
;;

(* ---- tests ---- *)

let base_cfg =
  { sim = { Sim.default_config with n_events = 20_000 }
  ; quoter =
      { Quoter.model =
          Quoter.Avellaneda_stoikov { gamma = 0.02; sigma = 3.; k = 1.5; horizon_s = 1. }
      ; qty = Qty.of_int 5
      ; max_inventory = 50
      }
  ; requote_every = 1
  ; markout_events = 100
  }
;;

let close a b = Float.abs (a -. b) < 1e-6 *. (1. +. Float.abs a +. Float.abs b)

let%test "the maker actually trades" =
  let r = run base_cfg in
  r.fills <> [] && r.volume > 0
;;

let%test "attribution sums exactly to total pnl" =
  List.for_all
    (fun markout ->
      let r = run { base_cfg with markout_events = markout } in
      let a = r.attribution in
      close (a.spread_capture +. a.adverse_selection +. a.inventory) r.total_pnl)
    [ 0; 1; 100; 5_000; 1_000_000 ]
;;

let%test "inventory equals the signed sum of fills" =
  let r = run base_cfg in
  let signed = List.fold_left (fun a f -> a + (Side.sign f.side * f.qty)) 0 r.fills in
  signed = r.final_inventory
;;

let%test "total pnl equals cash plus marked inventory, recomputed from fills" =
  let r = run base_cfg in
  let cash =
    List.fold_left
      (fun a f -> a -. float_of_int (Side.sign f.side * f.qty * f.price))
      0.
      r.fills
  in
  let last = r.mids.(Array.length r.mids - 1) in
  close r.total_pnl (cash +. (float_of_int r.final_inventory *. last))
;;

let%test "the inventory limit is never exceeded by more than one fill" =
  let limit = 20 in
  let r = run { base_cfg with quoter = { base_cfg.quoter with max_inventory = limit } } in
  (* A fill can overshoot by at most one quote size plus resting leftovers
     from the previous requote interval; with requote_every = 1 that is one
     quote size. *)
  Array.for_all (fun q -> abs q <= limit + Qty.to_int base_cfg.quoter.qty) r.inventory_path
;;

let%test "same config gives identical results" =
  let a = run base_cfg and b = run base_cfg in
  a.fills = b.fills && a.total_pnl = b.total_pnl
;;

(* Compares adverse selection per lot traded, not in total: more informed flow
   also means fewer fills, which shrinks any total. The news must be larger
   than the maker's half-spread for informed trading to bite, hence the high
   fundamental volatility. Averaged over seeds to damp noise. *)
let%test "informed flow costs the maker: adverse selection per lot worsens with it" =
  let per_lot informed =
    let seeds = [ 42; 7; 99; 1 ] in
    let vol, adverse =
      List.fold_left
        (fun (v, a) seed ->
          let r =
            run
              { base_cfg with
                sim =
                  { base_cfg.sim with
                    informed_prob = informed
                  ; fundamental_vol = 25.
                  ; n_events = 10_000
                  ; seed
                  }
              }
          in
          v + r.volume, a +. r.attribution.adverse_selection)
        (0, 0.)
        seeds
    in
    adverse /. float_of_int vol
  in
  per_lot 0.9 < per_lot 0.0 -. 0.2
;;

let%test "a lower inventory-aversion maker holds a larger inventory swing" =
  let spread_of gamma =
    let r =
      run
        { base_cfg with
          quoter =
            { base_cfg.quoter with
              model =
                Quoter.Avellaneda_stoikov { gamma; sigma = 3.; k = 1.5; horizon_s = 1. }
            }
        }
    in
    Array.fold_left (fun m q -> max m (abs q)) 0 r.inventory_path
  in
  spread_of 0.001 >= spread_of 0.5
;;
