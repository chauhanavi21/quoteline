type error =
  | Below_intrinsic
  | Above_upper_bound
  | No_time_value
  | Not_converged

let error_to_string = function
  | Below_intrinsic -> "price below intrinsic value"
  | Above_upper_bound -> "price above no-arbitrage upper bound"
  | No_time_value -> "zero expiry"
  | Not_converged -> "did not converge"
;;

let vol_lo = 1e-8
let vol_hi = 10.

let solve ?(tol = 1e-10) kind ~price ~spot ~strike ~rate ~expiry =
  if expiry <= 0.
  then Error No_time_value
  else (
    let disc_k = strike *. exp (-.rate *. expiry) in
    let lower, upper =
      match kind with
      | Bs.Call -> Float.max (spot -. disc_k) 0., spot
      | Bs.Put -> Float.max (disc_k -. spot) 0., disc_k
    in
    let f vol = Bs.price kind ~spot ~strike ~rate ~vol ~expiry -. price in
    if price < lower -. tol
    then Error Below_intrinsic
    else if price > upper +. tol
    then Error Above_upper_bound
    else if f vol_lo > 0. (* price at (almost) zero vol already exceeds target *)
    then if f vol_lo <= tol then Ok vol_lo else Error Below_intrinsic
    else if f vol_hi < 0.
    then Error Above_upper_bound
    else (
      let lo = ref vol_lo and hi = ref vol_hi in
      let vol = ref 0.3 in
      let result = ref None in
      let iter = ref 0 in
      while !result = None && !iter < 200 do
        incr iter;
        let fv = f !vol in
        if Float.abs fv <= tol
        then result := Some !vol
        else (
          (* f is increasing in vol, so the sign says which side we are on. *)
          if fv > 0. then hi := !vol else lo := !vol;
          let vega = (Bs.greeks kind ~spot ~strike ~rate ~vol:!vol ~expiry).vega in
          let newton = !vol -. (fv /. vega) in
          vol
          := if vega > 1e-12 && newton > !lo && newton < !hi
             then newton
             else 0.5 *. (!lo +. !hi))
      done;
      match !result with
      | Some v -> Ok v
      | None -> Error Not_converged))
;;

let%test "recovers the vol used to price, across the surface" =
  let spot = 100. and rate = 0.02 in
  List.for_all
    (fun kind ->
      List.for_all
        (fun (strike, vol, expiry) ->
          let price = Bs.price kind ~spot ~strike ~rate ~vol ~expiry in
          match solve kind ~price ~spot ~strike ~rate ~expiry with
          | Ok v ->
            (* Where price is insensitive to vol, only the price is pinned
               down; check the round trip in price terms too. *)
            let back = Bs.price kind ~spot ~strike ~rate ~vol:v ~expiry in
            Float.abs (back -. price) < 1e-9
            && (Float.abs (v -. vol) < 1e-6 || (Bs.greeks kind ~spot ~strike ~rate ~vol ~expiry).vega < 1e-4)
          | Error _ -> false)
        (List.concat_map
           (fun k ->
             List.concat_map
               (fun v -> List.map (fun t -> k, v, t) [ 0.02; 0.25; 1.; 5. ])
               [ 0.05; 0.2; 0.6; 1.5 ])
           [ 50.; 80.; 100.; 120.; 200. ]))
    [ Bs.Call; Bs.Put ]
;;

let%test "rejects prices outside no-arbitrage bounds" =
  let s kind price = solve kind ~price ~spot:100. ~strike:100. ~rate:0.05 ~expiry:1. in
  (* call lower bound = 100 - 100 e^-0.05 = 4.877; upper = spot = 100 *)
  s Bs.Call 4. = Error Below_intrinsic
  && s Bs.Call 101. = Error Above_upper_bound
  && s Bs.Put (-1.) = Error Below_intrinsic
  && solve Bs.Call ~price:5. ~spot:100. ~strike:100. ~rate:0.05 ~expiry:0. = Error No_time_value
;;

let%expect_test "known case: ATM call priced at 20% vol" =
  (match solve Bs.Call ~price:10.4506 ~spot:100. ~strike:100. ~rate:0.05 ~expiry:1. with
   | Ok v -> Printf.printf "implied vol = %.4f\n" v
   | Error e -> print_endline (error_to_string e));
  [%expect {| implied vol = 0.2000 |}]
;;
