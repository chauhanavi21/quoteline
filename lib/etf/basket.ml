type constituent =
  { name : string
  ; weight : float
  ; price : float
  ; half_spread : float
  }

let nav cs = List.fold_left (fun a c -> a +. (c.weight *. c.price)) 0. cs

type costs =
  { etf_half_spread : float
  ; creation_fee : float
  ; borrow_rate : float
  ; holding_days : float
  }

let round_trip_cost cs ~etf_price costs =
  let basket_spread = List.fold_left (fun a c -> a +. (c.weight *. c.half_spread)) 0. cs in
  let borrow = etf_price *. costs.borrow_rate *. costs.holding_days /. 365. in
  costs.etf_half_spread +. basket_spread +. costs.creation_fee +. borrow
;;

type direction =
  | Sell_etf_buy_basket
  | Buy_etf_sell_basket

type signal =
  { direction : direction
  ; gross_edge : float
  ; cost : float
  ; net_edge : float
  }

let signal cs ~etf_price costs =
  let gap = etf_price -. nav cs in
  let cost = round_trip_cost cs ~etf_price costs in
  let gross_edge = Float.abs gap in
  let net_edge = gross_edge -. cost in
  if net_edge <= 0.
  then None
  else (
    let direction = if gap > 0. then Sell_etf_buy_basket else Buy_etf_sell_basket in
    Some { direction; gross_edge; cost; net_edge })
;;

let pnl s ~shares = s.net_edge *. shares

let basket =
  [ { name = "AAA"; weight = 2.; price = 50.; half_spread = 0.01 }
  ; { name = "BBB"; weight = 1.; price = 30.; half_spread = 0.02 }
  ; { name = "CCC"; weight = 4.; price = 10.; half_spread = 0.005 }
  ]
;;

let costs =
  { etf_half_spread = 0.02; creation_fee = 0.05; borrow_rate = 0.0365; holding_days = 2. }
;;

let%expect_test "NAV and round-trip cost match hand calculation" =
  (* NAV = 2*50 + 1*30 + 4*10 = 170.
     basket spread = 2*0.01 + 1*0.02 + 4*0.005 = 0.06.
     borrow = 170 * 0.0365 * 2 / 365 = 0.034.
     cost = 0.02 + 0.06 + 0.05 + 0.034 = 0.164. *)
  Printf.printf "nav=%.4f cost=%.4f\n" (nav basket) (round_trip_cost basket ~etf_price:170. costs);
  [%expect {| nav=170.0000 cost=0.1640 |}]
;;

let%expect_test "signal direction, edge and pnl" =
  let show etf_price =
    match signal basket ~etf_price costs with
    | None -> Printf.printf "%.2f: no trade\n" etf_price
    | Some s ->
      Printf.printf
        "%.2f: %s gross=%.3f net=%.3f pnl(1000)=%.1f\n"
        etf_price
        (match s.direction with
         | Sell_etf_buy_basket -> "sell ETF / buy basket"
         | Buy_etf_sell_basket -> "buy ETF / sell basket")
        s.gross_edge
        s.net_edge
        (pnl s ~shares:1000.)
  in
  List.iter show [ 170.; 170.1; 170.5; 169.5; 169.9 ];
  [%expect {|
    170.00: no trade
    170.10: no trade
    170.50: sell ETF / buy basket gross=0.500 net=0.336 pnl(1000)=335.9
    169.50: buy ETF / sell basket gross=0.500 net=0.336 pnl(1000)=336.1
    169.90: no trade
    |}]
;;

let%test "a trade only fires when the gap exceeds the cost" =
  let c = round_trip_cost basket ~etf_price:170. costs in
  signal basket ~etf_price:(170. +. c -. 0.01) costs = None
  && signal basket ~etf_price:(170. +. c +. 0.01) costs <> None
  && signal basket ~etf_price:(170. -. c +. 0.01) costs = None
  && signal basket ~etf_price:(170. -. c -. 0.01) costs <> None
;;

let%test "net edge is never negative when a signal exists" =
  let rng = Random.State.make [| 4 |] in
  let ok = ref true in
  for _ = 1 to 5_000 do
    let etf_price = 160. +. Random.State.float rng 20. in
    match signal basket ~etf_price costs with
    | Some s -> if s.net_edge <= 0. || s.gross_edge < s.cost then ok := false
    | None -> ()
  done;
  !ok
;;
