open Core_types

type model =
  | Avellaneda_stoikov of
      { gamma : float
      ; sigma : float
      ; k : float
      ; horizon_s : float
      }
  | Fixed of { half_spread_ticks : float }

type params =
  { model : model
  ; qty : Qty.t
  ; max_inventory : int
  }

let reservation_price model ~mid ~inventory =
  match model with
  | Avellaneda_stoikov { gamma; sigma; horizon_s; _ } ->
    mid -. (float_of_int inventory *. gamma *. sigma *. sigma *. horizon_s)
  | Fixed _ -> mid
;;

let spread = function
  | Avellaneda_stoikov { gamma; sigma; k; horizon_s } ->
    (gamma *. sigma *. sigma *. horizon_s) +. (2. /. gamma *. log (1. +. (gamma /. k)))
  | Fixed { half_spread_ticks } -> 2. *. half_spread_ticks
;;

let quotes params ~mid ~inventory ~best_bid ~best_ask =
  let r = reservation_price params.model ~mid ~inventory in
  let half = spread params.model /. 2. in
  let bid = int_of_float (Float.floor (r -. half)) in
  let ask = int_of_float (Float.ceil (r +. half)) in
  (* Post-only: never cross the market. *)
  let bid = match best_ask with Some a -> min bid (a - 1) | None -> bid in
  let ask = match best_bid with Some b -> max ask (b + 1) | None -> ask in
  let bid = max bid 1 in
  (* After clamping the two sides can touch; keep a one-tick gap. *)
  let ask = max ask (bid + 1) in
  let bid = if inventory >= params.max_inventory then None else Some bid in
  let ask = if inventory <= -params.max_inventory then None else Some ask in
  bid, ask
;;

let as_model = Avellaneda_stoikov { gamma = 0.02; sigma = 3.; k = 1.5; horizon_s = 1. }
let params = { model = as_model; qty = Qty.of_int 5; max_inventory = 50 }

let%expect_test "A-S spread and reservation price match hand calculation" =
  (* gamma sigma^2 T = 0.02 * 9 * 1 = 0.18
     (2/gamma) ln(1 + gamma/k) = 100 * ln(1.013333) = 1.3245
     spread = 1.5045; reservation at q=10 is 10000 - 1.8 = 9998.2 *)
  Printf.printf "spread = %.4f\n" (spread as_model);
  Printf.printf "reservation(q=0)  = %.4f\n" (reservation_price as_model ~mid:10000. ~inventory:0);
  Printf.printf "reservation(q=10) = %.4f\n" (reservation_price as_model ~mid:10000. ~inventory:10);
  [%expect
    {|
    spread = 1.5045
    reservation(q=0)  = 10000.0000
    reservation(q=10) = 9998.2000 |}]
;;

let show (b, a) =
  let s = function Some p -> string_of_int p | None -> "-" in
  Printf.printf "bid=%s ask=%s\n" (s b) (s a)
;;

let%expect_test "long inventory shifts both quotes down, short shifts them up" =
  let q inventory =
    quotes params ~mid:10000. ~inventory ~best_bid:None ~best_ask:None |> show
  in
  q 0;
  q 20;
  q (-20);
  [%expect {|
    bid=9999 ask=10001
    bid=9995 ask=9998
    bid=10002 ask=10005
    |}]
;;

let%expect_test "quotes never cross the market" =
  quotes params ~mid:10000. ~inventory:(-30) ~best_bid:(Some 9995) ~best_ask:(Some 10003)
  |> show;
  quotes params ~mid:10000. ~inventory:30 ~best_bid:(Some 9995) ~best_ask:(Some 10003)
  |> show;
  [%expect {|
    bid=10002 ask=10007
    bid=9993 ask=9996
    |}]
;;

let%expect_test "inventory limit removes the side that would add risk" =
  let limited = { params with max_inventory = 10 } in
  quotes limited ~mid:10000. ~inventory:10 ~best_bid:None ~best_ask:None |> show;
  quotes limited ~mid:10000. ~inventory:(-10) ~best_bid:None ~best_ask:None |> show;
  [%expect {|
    bid=- ask=9999
    bid=10001 ask=-
    |}]
;;

let%test "bid is always below ask when both are quoted" =
  let rng = Random.State.make [| 7 |] in
  let ok = ref true in
  for _ = 1 to 5_000 do
    let mid = 9_900. +. Random.State.float rng 200. in
    let inventory = Random.State.int rng 81 - 40 in
    let bb = if Random.State.bool rng then Some (9_900 + Random.State.int rng 200) else None in
    let ba = if Random.State.bool rng then Some (9_900 + Random.State.int rng 200) else None in
    match quotes params ~mid ~inventory ~best_bid:bb ~best_ask:ba with
    | Some b, Some a -> if b >= a then ok := false
    | _ -> ()
  done;
  !ok
;;
