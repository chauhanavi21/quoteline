open Core_types

let px n = Price.of_ticks n
let q n = Qty.of_int n

let order id side price qty : Book.order =
  { id = Order_id.of_int id; side; price = px price; qty = q qty }
;;

let show_trade (t : Book.trade) =
  Printf.sprintf
    "taker=%s maker=%s %s %s@%d"
    (Order_id.to_string t.taker)
    (Order_id.to_string t.maker)
    (Side.to_string t.taker_side)
    (Qty.to_string t.qty)
    (Price.to_ticks t.price)
;;

let show_levels book side =
  Book.levels book side
  |> List.map (fun (p, n) -> Printf.sprintf "%d x %s" (Price.to_ticks p) (Qty.to_string n))
  |> String.concat ", "
;;

let apply book (o : Book.order) ~rest =
  let book, trades = Book.add book o ~rest in
  List.iter (fun t -> print_endline (show_trade t)) trades;
  (match Book.check_invariants book with
   | Ok () -> ()
   | Error e -> failwith ("invariant violated: " ^ e));
  book
;;

let%expect_test "resting orders do not trade when not crossing" =
  let b = Book.empty in
  let b = apply b (order 1 Buy 99 10) ~rest:true in
  let b = apply b (order 2 Sell 101 5) ~rest:true in
  Printf.printf "bids: %s\nasks: %s\n" (show_levels b Buy) (show_levels b Sell);
  [%expect {|
    bids: 99 x 10
    asks: 101 x 5 |}]
;;

let%expect_test "price priority: best price fills first, at the maker's price" =
  let b = Book.empty in
  let b = apply b (order 1 Sell 102 5) ~rest:true in
  let b = apply b (order 2 Sell 101 5) ~rest:true in
  let b = apply b (order 3 Buy 103 7) ~rest:true in
  Printf.printf "asks: %s\n" (show_levels b Sell);
  [%expect {|
    taker=3 maker=2 BUY 5@101
    taker=3 maker=1 BUY 2@102
    asks: 102 x 3 |}]
;;

let%expect_test "time priority: older order at the same price fills first" =
  let b = Book.empty in
  let b = apply b (order 1 Buy 100 4) ~rest:true in
  let b = apply b (order 2 Buy 100 4) ~rest:true in
  let b = apply b (order 3 Sell 100 6) ~rest:true in
  Printf.printf "bids: %s\n" (show_levels b Buy);
  [%expect {|
    taker=3 maker=1 SELL 4@100
    taker=3 maker=2 SELL 2@100
    bids: 100 x 2 |}]
;;

let%expect_test "partially filled maker keeps its place at the front" =
  let b = Book.empty in
  let b = apply b (order 1 Sell 100 10) ~rest:true in
  let b = apply b (order 2 Sell 100 10) ~rest:true in
  let b = apply b (order 3 Buy 100 3) ~rest:true in
  let b = apply b (order 4 Buy 100 3) ~rest:true in
  ignore b;
  [%expect {|
    taker=3 maker=1 BUY 3@100
    taker=4 maker=1 BUY 3@100 |}]
;;

let%expect_test "IOC remainder is discarded, resting remainder joins the book" =
  let b = Book.empty in
  let b = apply b (order 1 Sell 100 5) ~rest:true in
  let ioc = apply b (order 2 Buy 100 8) ~rest:false in
  Printf.printf "IOC  bids: [%s] asks: [%s]\n" (show_levels ioc Buy) (show_levels ioc Sell);
  let gtc = apply b (order 3 Buy 100 8) ~rest:true in
  Printf.printf "GTC  bids: [%s] asks: [%s]\n" (show_levels gtc Buy) (show_levels gtc Sell);
  [%expect {|
    taker=2 maker=1 BUY 5@100
    IOC  bids: [] asks: []
    taker=3 maker=1 BUY 5@100
    GTC  bids: [100 x 3] asks: [] |}]
;;

let%expect_test "cancel removes an order and reports unknown ids" =
  let b = Book.empty in
  let b = apply b (order 1 Buy 99 10) ~rest:true in
  let b =
    match Book.cancel b (Order_id.of_int 1) with
    | Some (b, o) ->
      Printf.printf "cancelled %s\n" (Order_id.to_string o.id);
      b
    | None -> b
  in
  Printf.printf "count=%d\n" (Book.order_count b);
  Printf.printf "unknown: %b\n" (Book.cancel b (Order_id.of_int 42) = None);
  [%expect {|
    cancelled 1
    count=0
    unknown: true |}]
;;

let%expect_test "duplicate order id is rejected" =
  let b = apply Book.empty (order 1 Buy 99 10) ~rest:true in
  (try ignore (Book.add b (order 1 Buy 98 1) ~rest:true)
   with Invalid_argument m -> print_endline m);
  [%expect {| Book.add: duplicate order id 1 |}]
;;

(* Randomised property: after any sequence of adds and cancels the structural
   invariants hold, traded quantity is conserved, and trades only happen at
   prices that cross the taker's limit. Uses a fixed-seed PRNG so failures
   are reproducible. *)
let%test "random operation sequences preserve invariants and conserve volume" =
  let rng = Random.State.make [| 20240229 |] in
  let ok = ref true in
  for _run = 1 to 300 do
    let gen = Order_id.Gen.create () in
    let book = ref Book.empty in
    let live = ref [] in
    for _step = 1 to 200 do
      if Random.State.int rng 4 = 0 && !live <> [] then (
        let i = Random.State.int rng (List.length !live) in
        let id = List.nth !live i in
        match Book.cancel !book id with
        | Some (b, _) -> book := b
        | None -> ())
      else (
        let side = if Random.State.bool rng then Side.Buy else Side.Sell in
        let price = 95 + Random.State.int rng 11 in
        let qty = 1 + Random.State.int rng 20 in
        let rest = Random.State.int rng 5 <> 0 in
        let id = Order_id.Gen.next gen in
        let o : Book.order = { id; side; price = px price; qty = q qty } in
        let before = Book.total_qty !book (Side.opposite side) in
        let b, trades = Book.add !book o ~rest in
        let traded =
          List.fold_left (fun a (t : Book.trade) -> a + Qty.to_int t.qty) 0 trades
        in
        let after = Book.total_qty b (Side.opposite side) in
        (* maker-side quantity removed equals traded quantity *)
        if Qty.to_int before - Qty.to_int after <> traded then ok := false;
        (* every trade is at a price the taker accepts *)
        List.iter
          (fun (t : Book.trade) ->
            let good =
              match side with
              | Side.Buy -> Price.to_ticks t.price <= price
              | Side.Sell -> Price.to_ticks t.price >= price
            in
            if not good then ok := false)
          trades;
        if rest && traded < qty then live := id :: !live;
        book := b);
      match Book.check_invariants !book with
      | Ok () -> ()
      | Error _ -> ok := false
    done
  done;
  !ok
;;
