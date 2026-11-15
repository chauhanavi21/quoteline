open Core_types

type order =
  { id : Order_id.t
  ; side : Side.t
  ; price : Price.t
  ; qty : Qty.t
  }

type trade =
  { taker : Order_id.t
  ; maker : Order_id.t
  ; taker_side : Side.t
  ; price : Price.t
  ; qty : Qty.t
  }

module PMap = Map.Make (Price)
module IMap = Map.Make (Order_id)
module SMap = Map.Make (Int)

(* A price level holds its orders in a map keyed by arrival sequence number, so
   the oldest order is the minimum key. That makes every operation O(log n) in
   the level's size: pop the oldest, cancel by id, and keep a partially filled
   order at the front (it retains its original sequence number). The level also
   caches its total quantity, so reading depth never walks the orders. *)
module Level = struct
  type t =
    { orders : order SMap.t
    ; total : int
    }

  let empty = { orders = SMap.empty; total = 0 }
  let is_empty t = SMap.is_empty t.orders

  let add t ~seq (o : order) =
    { orders = SMap.add seq o t.orders; total = t.total + Qty.to_int o.qty }
  ;;

  let oldest t = SMap.min_binding_opt t.orders

  (* Replace the order at [seq] (used for a partial fill: same place in the queue). *)
  let replace t ~seq (o : order) =
    match SMap.find_opt seq t.orders with
    | None -> invalid_arg "Book.Level.replace: unknown sequence number"
    | Some old ->
      { orders = SMap.add seq o t.orders
      ; total = t.total - Qty.to_int old.qty + Qty.to_int o.qty
      }
  ;;

  let remove t ~seq =
    match SMap.find_opt seq t.orders with
    | None -> t
    | Some o -> { orders = SMap.remove seq t.orders; total = t.total - Qty.to_int o.qty }
  ;;

  let find t ~seq = SMap.find_opt seq t.orders
  let total_qty t = Qty.of_int t.total
  let to_list t = List.map snd (SMap.bindings t.orders)
end

type t =
  { bids : Level.t PMap.t
  ; asks : Level.t PMap.t
  ; index : (Side.t * Price.t * int) IMap.t  (* side, price, arrival sequence number *)
  ; next_seq : int
  }

let empty = { bids = PMap.empty; asks = PMap.empty; index = IMap.empty; next_seq = 0 }

let side_map t = function
  | Side.Buy -> t.bids
  | Side.Sell -> t.asks
;;

let with_side_map t side m =
  match side with
  | Side.Buy -> { t with bids = m }
  | Side.Sell -> { t with asks = m }
;;

(* Best price on a side: highest bid, lowest ask. *)
let best_binding t side =
  match side with
  | Side.Buy -> PMap.max_binding_opt t.bids
  | Side.Sell -> PMap.min_binding_opt t.asks
;;

let update_level t side price f =
  let m = side_map t side in
  let level = Option.value (PMap.find_opt price m) ~default:Level.empty in
  let level = f level in
  let m = if Level.is_empty level then PMap.remove price m else PMap.add price level m in
  with_side_map t side m
;;

(* Would a taker on [side] with limit [limit] trade against resting [best]? *)
let crosses side ~limit ~best =
  match side with
  | Side.Buy -> Price.compare best limit <= 0
  | Side.Sell -> Price.compare best limit >= 0
;;

let add t (order : order) ~rest =
  if IMap.mem order.id t.index then
    invalid_arg ("Book.add: duplicate order id " ^ Order_id.to_string order.id);
  let opp = Side.opposite order.side in
  let rec loop t remaining trades =
    if Qty.is_zero remaining then t, remaining, trades
    else (
      match best_binding t opp with
      | Some (px, level) when crosses order.side ~limit:order.price ~best:px ->
        (match Level.oldest level with
         | None -> assert false (* empty levels are never stored *)
         | Some (seq, maker) ->
           let fill = Qty.min remaining maker.qty in
           let trade =
             { taker = order.id
             ; maker = maker.id
             ; taker_side = order.side
             ; price = px
             ; qty = fill
             }
           in
           let maker_left = Qty.sub maker.qty fill in
           let level' =
             if Qty.is_zero maker_left
             then Level.remove level ~seq
             else Level.replace level ~seq { maker with qty = maker_left }
           in
           let m = side_map t opp in
           let m = if Level.is_empty level' then PMap.remove px m else PMap.add px level' m in
           let t = with_side_map t opp m in
           let t =
             if Qty.is_zero maker_left then { t with index = IMap.remove maker.id t.index }
             else t
           in
           loop t (Qty.sub remaining fill) (trade :: trades))
      | _ -> t, remaining, trades)
  in
  let t, remaining, trades = loop t order.qty [] in
  let t =
    if rest && not (Qty.is_zero remaining)
    then (
      let resting = { order with qty = remaining } in
      let seq = t.next_seq in
      let t = update_level t order.side order.price (fun l -> Level.add l ~seq resting) in
      { t with
        index = IMap.add order.id (order.side, order.price, seq) t.index
      ; next_seq = seq + 1
      })
    else t
  in
  t, List.rev trades
;;

let find t id =
  match IMap.find_opt id t.index with
  | None -> None
  | Some (side, price, seq) ->
    (match PMap.find_opt price (side_map t side) with
     | None -> None
     | Some level -> Level.find level ~seq)
;;

let cancel t id =
  match IMap.find_opt id t.index with
  | None -> None
  | Some (side, price, seq) ->
    (match find t id with
     | None -> None
     | Some order ->
       let t = update_level t side price (fun l -> Level.remove l ~seq) in
       Some ({ t with index = IMap.remove id t.index }, order))
;;

let best side t =
  match best_binding t side with
  | None -> None
  | Some (px, level) -> Some (px, Level.total_qty level)
;;

let best_bid t = best Side.Buy t
let best_ask t = best Side.Sell t

let mid t =
  match best_bid t, best_ask t with
  | Some (b, _), Some (a, _) ->
    Some (float_of_int (Price.to_ticks b + Price.to_ticks a) /. 2.)
  | _ -> None
;;

let total_qty t side =
  PMap.fold (fun _ l acc -> Qty.add acc (Level.total_qty l)) (side_map t side) Qty.zero
;;

let order_count t = IMap.cardinal t.index

let levels t side =
  let bindings = PMap.bindings (side_map t side) in
  let bindings = match side with Side.Buy -> List.rev bindings | Side.Sell -> bindings in
  List.map (fun (px, l) -> px, Level.total_qty l) bindings
;;

let check_invariants t =
  let ( let* ) = Result.bind in
  let check_side side =
    PMap.fold
      (fun px level acc ->
        let* () = acc in
        if Level.is_empty level then Error "empty level stored"
        else
          List.fold_left
            (fun acc (o : order) ->
              let* () = acc in
              if Qty.is_zero o.qty then Error "zero-quantity resting order"
              else if not (Price.equal o.price px) then Error "order price differs from level"
              else if o.side <> side then Error "order on wrong side"
              else
                match IMap.find_opt o.id t.index with
                | Some (s, p, _) when s = side && Price.equal p px -> Ok ()
                | _ -> Error "index disagrees with level")
            (Ok ()) (Level.to_list level))
      (side_map t side) (Ok ())
  in
  let check_totals side =
    PMap.fold
      (fun _ level acc ->
        let* () = acc in
        let recomputed =
          List.fold_left (fun a (o : order) -> a + Qty.to_int o.qty) 0 (Level.to_list level)
        in
        if recomputed <> Qty.to_int (Level.total_qty level)
        then Error "cached level total disagrees with its orders"
        else Ok ())
      (side_map t side)
      (Ok ())
  in
  let* () = check_side Side.Buy in
  let* () = check_side Side.Sell in
  let* () = check_totals Side.Buy in
  let* () = check_totals Side.Sell in
  let level_orders =
    List.fold_left
      (fun n s ->
        PMap.fold (fun _ l n -> n + List.length (Level.to_list l)) (side_map t s) n)
      0 [ Side.Buy; Side.Sell ]
  in
  let* () =
    if level_orders <> IMap.cardinal t.index then Error "index size differs from order count"
    else Ok ()
  in
  match best_binding t Side.Buy, best_binding t Side.Sell with
  | Some (bid, _), Some (ask, _) when Price.compare bid ask >= 0 -> Error "book is crossed"
  | _ -> Ok ()
;;
