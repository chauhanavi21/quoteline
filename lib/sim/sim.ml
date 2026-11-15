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
  { time_us : int
  ; id : Order_id.t
  ; action : action
  }

type config =
  { seed : int
  ; n_events : int
  ; start_mid : Price.t
  ; arrival_rate_per_s : float
  ; mean_lifetime_events : float
  ; market_prob : float
  ; mean_offset_ticks : float
  ; mean_qty : float
  ; fundamental_vol : float
  ; informed_prob : float
  ; news_lag_events : float
  }

let default_config =
  { seed = 42
  ; n_events = 10_000
  ; start_mid = Price.of_ticks 10_000
  ; arrival_rate_per_s = 1_000.
  ; mean_lifetime_events = 500.
  ; market_prob = 0.15
  ; mean_offset_ticks = 6.
  ; mean_qty = 10.
  ; fundamental_vol = 3.
  ; informed_prob = 0.3
  ; news_lag_events = 200.
  }
;;

type step =
  { event : event
  ; trades : Book.trade list
  ; book : Book.t
  }

(* Exponential variate with the given mean. [1 - u] keeps the log argument in
   (0, 1], so it never hits [log 0]. *)
let exponential rng ~mean = -.mean *. log (1. -. Random.State.float rng 1.)

(* Standard normal via Box-Muller. *)
let gaussian rng =
  let u1 = 1. -. Random.State.float rng 1. in
  let u2 = Random.State.float rng 1. in
  sqrt (-2. *. log u1) *. cos (2. *. Float.pi *. u2)
;;

let random_side rng = if Random.State.bool rng then Side.Buy else Side.Sell

let random_qty rng ~mean =
  Qty.of_int (1 + int_of_float (exponential rng ~mean:(mean -. 1.)))
;;

let apply book event =
  match event.action with
  | Cancel id ->
    (match Book.cancel book id with
     | Some (b, _) -> b, []
     | None -> book, [] (* already filled: harmless no-op *))
  | Limit { side; price; qty } -> Book.add book { id = event.id; side; price; qty } ~rest:true
  | Market { side; qty } ->
    (* A market order is an IOC order priced through the whole book. *)
    let limit = match side with Side.Buy -> max_int / 2 | Side.Sell -> 0 in
    Book.add book { id = event.id; side; price = Price.of_ticks limit; qty } ~rest:false
;;

module IntMap = Map.Make (Int)

let validate cfg =
  let bad msg = invalid_arg ("Sim.config: " ^ msg) in
  if cfg.n_events < 0 then bad "n_events must be >= 0";
  if not (Float.is_finite cfg.arrival_rate_per_s && cfg.arrival_rate_per_s > 0.)
  then bad "arrival_rate_per_s must be finite and > 0";
  if not (cfg.market_prob >= 0. && cfg.market_prob <= 1.) then bad "market_prob must be in [0, 1]";
  if not (cfg.informed_prob >= 0. && cfg.informed_prob <= 1.) then bad "informed_prob must be in [0, 1]";
  if not (Float.is_finite cfg.mean_offset_ticks && cfg.mean_offset_ticks > 0.)
  then bad "mean_offset_ticks must be finite and > 0";
  if not (Float.is_finite cfg.mean_qty && cfg.mean_qty >= 1.) then bad "mean_qty must be finite and >= 1";
  if not (Float.is_finite cfg.mean_lifetime_events && cfg.mean_lifetime_events > 0.)
  then bad "mean_lifetime_events must be finite and > 0";
  if not (Float.is_finite cfg.fundamental_vol && cfg.fundamental_vol >= 0.)
  then bad "fundamental_vol must be finite and >= 0";
  if not (Float.is_finite cfg.news_lag_events && cfg.news_lag_events >= 1.)
  then bad "news_lag_events must be finite and >= 1"
;;

module Flow = struct
  type t =
    { cfg : config
    ; rng : Random.State.t
    ; ids : Order_id.Gen.t
    ; mean_gap_us : float
    ; mutable remaining : int
    ; mutable step : int
    ; mutable time_us : int
    ; mutable anchor : float  (* lagged fundamental that passive orders quote around *)
    ; mutable fundamental : float
    ; mutable expiries : Order_id.t list IntMap.t  (* step -> orders that expire then *)
    }

  let create cfg =
    validate cfg;
    { cfg
    ; rng = Random.State.make [| cfg.seed |]
    ; ids = Order_id.Gen.create ()
    ; mean_gap_us = 1_000_000. /. cfg.arrival_rate_per_s
    ; remaining = cfg.n_events
    ; step = 0
    ; time_us = 0
    ; anchor = float_of_int (Price.to_ticks cfg.start_mid)
    ; fundamental = float_of_int (Price.to_ticks cfg.start_mid)
    ; expiries = IntMap.empty
    }
  ;;

  let ids t = t.ids
  let fundamental t = t.fundamental

  let new_limit t ~time_us =
    let id = Order_id.Gen.next t.ids in
    let side = random_side t.rng in
    (* Always at least one tick from the anchor, on the passive side of it. *)
    let off = 1 + int_of_float (exponential t.rng ~mean:t.cfg.mean_offset_ticks) in
    let m = int_of_float (Float.round t.anchor) in
    let price =
      Price.of_ticks (max 1 (match side with Side.Buy -> m - off | Side.Sell -> m + off))
    in
    let qty = random_qty t.rng ~mean:t.cfg.mean_qty in
    let lifetime = 1 + int_of_float (exponential t.rng ~mean:t.cfg.mean_lifetime_events) in
    t.expiries
    <- IntMap.update
         (t.step + lifetime)
         (fun l -> Some (id :: Option.value l ~default:[]))
         t.expiries;
    { time_us; id; action = Limit { side; price; qty } }
  ;;

  let new_market t ~book ~time_us =
    let id = Order_id.Gen.next t.ids in
    (* Always draw both, so the amount of randomness used per event does not
       depend on which branch is taken. *)
    let informed = Random.State.float t.rng 1. < t.cfg.informed_prob in
    let noise_side = random_side t.rng in
    (* An informed trader only crosses the spread when it is worth it: buy if
       the fundamental is above the best ask, sell if it is below the best bid. *)
    let side =
      let px = Option.map (fun (p, _) -> float_of_int (Price.to_ticks p)) in
      match informed, px (Book.best_bid book), px (Book.best_ask book) with
      | true, _, Some ask when t.fundamental > ask -> Side.Buy
      | true, Some bid, _ when t.fundamental < bid -> Side.Sell
      | _ -> noise_side
    in
    { time_us; id; action = Market { side; qty = random_qty t.rng ~mean:t.cfg.mean_qty } }
  ;;

  let next ?fundamental t ~book =
    if t.remaining = 0 then None
    else (
      t.remaining <- t.remaining - 1;
      t.step <- t.step + 1;
      let gap_us = 1 + int_of_float (exponential t.rng ~mean:t.mean_gap_us) in
      t.time_us <- t.time_us + gap_us;
      let dt = float_of_int gap_us /. 1_000_000. in
      (* Always draw the Gaussian, so the random stream is the same whether or
         not the caller supplies the fundamental. *)
      let shock = gaussian t.rng in
      (match fundamental with
       | Some f -> t.fundamental <- f
       | None -> t.fundamental <- t.fundamental +. (t.cfg.fundamental_vol *. sqrt dt *. shock));
      t.anchor <- t.anchor +. ((t.fundamental -. t.anchor) /. t.cfg.news_lag_events);
      let time_us = t.time_us in
      let u = Random.State.float t.rng 1. in
      let event =
        match IntMap.min_binding_opt t.expiries with
        | Some (due, id :: rest) when due <= t.step ->
          (* The order may already have been filled; [apply] treats a cancel
             of a missing order as a no-op. *)
          t.expiries
          <- (if rest = [] then IntMap.remove due t.expiries else IntMap.add due rest t.expiries);
          { time_us; id; action = Cancel id }
        | _ ->
          if u < t.cfg.market_prob
          then new_market t ~book ~time_us
          else new_limit t ~time_us
      in
      Some event)
  ;;
end

let run cfg =
  let flow = Flow.create cfg in
  let rec loop book acc =
    match Flow.next flow ~book with
    | None -> List.rev acc
    | Some event ->
      let book, trades = apply book event in
      loop book ({ event; trades; book } :: acc)
  in
  loop Book.empty []
;;

let event_to_csv e =
  let kind, side, price, qty =
    match e.action with
    | Limit { side; price; qty } ->
      "LIMIT", Side.to_string side, string_of_int (Price.to_ticks price), Qty.to_string qty
    | Market { side; qty } -> "MARKET", Side.to_string side, "", Qty.to_string qty
    | Cancel _ -> "CANCEL", "", "", ""
  in
  Printf.sprintf "%d,%s,%s,%s,%s,%s" e.time_us (Order_id.to_string e.id) kind side price qty
;;

let trade_to_csv ~time_us (t : Book.trade) =
  Printf.sprintf
    "%d,%s,%s,%s,%d,%s"
    time_us
    (Order_id.to_string t.taker)
    (Order_id.to_string t.maker)
    (Side.to_string t.taker_side)
    (Price.to_ticks t.price)
    (Qty.to_string t.qty)
;;

let%test "same seed gives identical event logs" =
  let cfg = { default_config with n_events = 2_000 } in
  let log () = List.map (fun s -> event_to_csv s.event) (run cfg) in
  log () = log ()
;;

let%test "different seeds give different logs" =
  let a = { default_config with n_events = 500; seed = 1 } in
  let b = { a with seed = 2 } in
  List.map (fun s -> event_to_csv s.event) (run a)
  <> List.map (fun s -> event_to_csv s.event) (run b)
;;

let%test "book invariants hold after every simulated event" =
  List.for_all
    (fun s -> Book.check_invariants s.book = Ok ())
    (run { default_config with n_events = 5_000 })
;;

let%test "simulation produces trades" =
  List.exists (fun s -> s.trades <> []) (run { default_config with n_events = 5_000 })
;;

let%test "stepping the flow by hand matches run" =
  let cfg = { default_config with n_events = 1_000 } in
  let flow = Flow.create cfg in
  let rec go book acc =
    match Flow.next flow ~book with
    | None -> List.rev acc
    | Some e -> go (fst (apply book e)) (event_to_csv e :: acc)
  in
  go Book.empty [] = List.map (fun s -> event_to_csv s.event) (run cfg)
;;

let%test "invalid configurations are rejected, valid ones are not" =
  let bad c = try ignore (Flow.create c); false with Invalid_argument _ -> true in
  bad { default_config with n_events = -1 }
  && bad { default_config with arrival_rate_per_s = -1000. }
  && bad { default_config with arrival_rate_per_s = 0. }
  && bad { default_config with arrival_rate_per_s = Float.nan }
  && bad { default_config with market_prob = 1.5 }
  && bad { default_config with informed_prob = -0.1 }
  && bad { default_config with mean_offset_ticks = 0. }
  && bad { default_config with mean_qty = 0.5 }
  && bad { default_config with mean_lifetime_events = Float.infinity }
  && bad { default_config with news_lag_events = 0. }
  && (not (bad default_config))
  && not (bad { default_config with n_events = 0 })
;;

let%test "timestamps are positive and strictly increasing" =
  let steps = run { default_config with n_events = 2_000 } in
  let rec ok prev = function
    | [] -> true
    | (s : step) :: rest -> s.event.time_us > prev && ok s.event.time_us rest
  in
  ok 0 steps
;;
