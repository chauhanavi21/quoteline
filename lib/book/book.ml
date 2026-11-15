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

(* A price level is a persistent FIFO queue: [front] is oldest-first, [back]
   is newest-first. Amortised O(1) push and pop. *)
module Level = struct
  type t =
    { front : order list
    ; back : order list
    }

  let empty = { front = []; back = [] }
  let is_empty t = t.front = [] && t.back = []
  let push_back t o = { t with back = o :: t.back }
  let push_front t o = { t with front = o :: t.front }

  let pop_front t =
    match t.front with
    | o :: front -> Some (o, { t with front })
    | [] ->
      (match List.rev t.back with
       | [] -> None
       | o :: front -> Some (o, { front; back = [] }))
  ;;

  let to_list t = t.front @ List.rev t.back

  let total_qty t =
    List.fold_left (fun acc (o : order) -> Qty.add acc o.qty) Qty.zero (to_list t)
  ;;

  let remove t id =
    let keep o = not (Order_id.equal o.id id) in
    { front = List.filter keep t.front; back = List.filter keep t.back }
  ;;
end

type t =
  { bids : Level.t PMap.t
  ; asks : Level.t PMap.t
  ; index : (Side.t * Price.t) IMap.t
  }

let empty = { bids = PMap.empty; asks = PMap.empty; index = IMap.empty }

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
        (match Level.pop_front level with
         | None -> assert false (* empty levels are never stored *)
         | Some (maker, level') ->
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
           let level'' =
             if Qty.is_zero maker_left then level'
             else Level.push_front level' { maker with qty = maker_left }
           in
           let m = side_map t opp in
           let m =
             if Level.is_empty level'' then PMap.remove px m
             else PMap.add px level'' m
           in
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
    if rest && not (Qty.is_zero remaining) then (
      let resting = { order with qty = remaining } in
      let t = update_level t order.side order.price (fun l -> Level.push_back l resting) in
      { t with index = IMap.add order.id (order.side, order.price) t.index })
    else t
  in
  t, List.rev trades
;;

let find t id =
  match IMap.find_opt id t.index with
  | None -> None
  | Some (side, price) ->
    (match PMap.find_opt price (side_map t side) with
     | None -> None
     | Some level ->
       List.find_opt (fun o -> Order_id.equal o.id id) (Level.to_list level))
;;

let cancel t id =
  match find t id with
  | None -> None
  | Some order ->
    let t = update_level t order.side order.price (fun l -> Level.remove l id) in
    Some ({ t with index = IMap.remove id t.index }, order)
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
                | Some (s, p) when s = side && Price.equal p px -> Ok ()
                | _ -> Error "index disagrees with level")
            (Ok ()) (Level.to_list level))
      (side_map t side) (Ok ())
  in
  let* () = check_side Side.Buy in
  let* () = check_side Side.Sell in
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
