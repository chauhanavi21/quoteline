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
  ; cancel_prob : float
  ; market_prob : float
  ; mean_offset_ticks : float
  ; mean_qty : float
  }

let default_config =
  { seed = 42
  ; n_events = 10_000
  ; start_mid = Price.of_ticks 10_000
  ; arrival_rate_per_s = 1_000.
  ; cancel_prob = 0.25
  ; market_prob = 0.15
  ; mean_offset_ticks = 6.
  ; mean_qty = 10.
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

let random_side rng = if Random.State.bool rng then Side.Buy else Side.Sell

let random_qty rng ~mean =
  Qty.of_int (1 + int_of_float (exponential rng ~mean:(mean -. 1.)))
;;

(* Reference price for placing new orders: the book midpoint when both sides
   exist, otherwise the last known mid. *)
let mid_of book ~fallback =
  match Book.best_bid book, Book.best_ask book with
  | Some (b, _), Some (a, _) -> Price.of_ticks ((Price.to_ticks b + Price.to_ticks a) / 2)
  | _ -> fallback
;;

let run cfg =
  let rng = Random.State.make [| cfg.seed |] in
  let ids = Order_id.Gen.create () in
  let mean_gap_us = 1_000_000. /. cfg.arrival_rate_per_s in
  let rec loop n time_us book mid resting acc =
    if n = 0 then List.rev acc
    else (
      let time_us = time_us + 1 + int_of_float (exponential rng ~mean:mean_gap_us) in
      let u = Random.State.float rng 1. in
      let cancel_roll = u < cfg.cancel_prob && resting <> [] in
      let event, resting =
        if cancel_roll then (
          let i = Random.State.int rng (List.length resting) in
          let victim = List.nth resting i in
          let resting = List.filteri (fun j _ -> j <> i) resting in
          { time_us; id = victim; action = Cancel victim }, resting)
        else if u < cfg.cancel_prob +. cfg.market_prob then (
          let id = Order_id.Gen.next ids in
          let side = random_side rng in
          { time_us; id; action = Market { side; qty = random_qty rng ~mean:cfg.mean_qty } }, resting)
        else (
          let id = Order_id.Gen.next ids in
          let side = random_side rng in
          (* Always at least one tick from mid, on the passive side of it. *)
          let off = 1 + int_of_float (exponential rng ~mean:cfg.mean_offset_ticks) in
          let m = Price.to_ticks mid in
          let price = Price.of_ticks (match side with Side.Buy -> m - off | Side.Sell -> m + off) in
          ( { time_us; id; action = Limit { side; price; qty = random_qty rng ~mean:cfg.mean_qty } }
          , resting ))
      in
      let book', trades, resting =
        match event.action with
        | Cancel id ->
          (match Book.cancel book id with
           | Some (b, _) -> b, [], resting
           | None -> book, [], resting (* already filled: harmless no-op *))
        | Limit { side; price; qty } ->
          let b, trades = Book.add book { id = event.id; side; price; qty } ~rest:true in
          let still_rests = Book.find b event.id <> None in
          b, trades, if still_rests then event.id :: resting else resting
        | Market { side; qty } ->
          (* A market order is an IOC order priced through the whole book. *)
          let limit = match side with Side.Buy -> max_int / 2 | Side.Sell -> 0 in
          let b, trades =
            Book.add book { id = event.id; side; price = Price.of_ticks limit; qty } ~rest:false
          in
          b, trades, resting
      in
      (* Drop ids that were filled by this event's trades from the cancel pool. *)
      let resting =
        match trades with
        | [] -> resting
        | _ -> List.filter (fun id -> Book.find book' id <> None) resting
      in
      let mid = mid_of book' ~fallback:mid in
      loop (n - 1) time_us book' mid resting ({ event; trades; book = book' } :: acc))
  in
  loop cfg.n_events 0 Book.empty cfg.start_mid [] []
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
