let check ~confidence pnl =
  if Array.length pnl = 0 then invalid_arg "Var: empty sample";
  if not (confidence > 0. && confidence < 1.) then
    invalid_arg "Var: confidence must be in (0, 1)"
;;

(* Number of outcomes in the tail, at least 1. *)
let tail_size ~confidence n =
  max 1 (int_of_float (Float.ceil ((float_of_int n *. (1. -. confidence)) -. 1e-9)))
;;

let sorted_ascending pnl =
  let a = Array.copy pnl in
  Array.sort compare a;
  a
;;

let var ~confidence pnl =
  check ~confidence pnl;
  let a = sorted_ascending pnl in
  let k = tail_size ~confidence (Array.length a) in
  (* The k-th worst outcome is the tail boundary. *)
  -.a.(k - 1)
;;

let expected_shortfall ~confidence pnl =
  check ~confidence pnl;
  let a = sorted_ascending pnl in
  let k = tail_size ~confidence (Array.length a) in
  let s = ref 0. in
  for i = 0 to k - 1 do
    s := !s +. a.(i)
  done;
  -. !s /. float_of_int k
;;

let normal_var ~confidence ~mean ~std =
  -.mean +. (std *. Options.Normal.inv_cdf confidence)
;;

let normal_es ~confidence ~mean ~std =
  let z = Options.Normal.inv_cdf confidence in
  -.mean +. (std *. Options.Normal.pdf z /. (1. -. confidence))
;;

let%expect_test "hand-checkable small sample" =
  (* 20 outcomes: -10, -9, ..., 9. At 90%, the tail is ceil(20 * 0.1) = 2
     outcomes: -10 and -9. VaR = 9 (the 2nd worst), ES = (10 + 9) / 2 = 9.5. *)
  let pnl = Array.init 20 (fun i -> float_of_int (i - 10)) in
  Printf.printf "VaR90=%.2f ES90=%.2f\n" (var ~confidence:0.9 pnl) (expected_shortfall ~confidence:0.9 pnl);
  Printf.printf "VaR95=%.2f ES95=%.2f\n" (var ~confidence:0.95 pnl) (expected_shortfall ~confidence:0.95 pnl);
  [%expect {|
    VaR90=9.00 ES90=9.50
    VaR95=10.00 ES95=10.00 |}]
;;

let%test "ES is never smaller than VaR, and both are monotone in confidence" =
  let rng = Random.State.make [| 5 |] in
  let pnl = Array.init 5_000 (fun _ -> Random.State.float rng 200. -. 100.) in
  let cs = [ 0.9; 0.95; 0.975; 0.99; 0.999 ] in
  let vars = List.map (fun c -> var ~confidence:c pnl) cs in
  let ess = List.map (fun c -> expected_shortfall ~confidence:c pnl) cs in
  List.for_all2 (fun v e -> e >= v -. 1e-12) vars ess
  && List.sort compare vars = vars
  && List.sort compare ess = ess
;;

let%test "normal closed forms: textbook z-scores" =
  (* N(0, 1): VaR99 = 2.3263, ES99 = pdf(2.3263) / 0.01 = 2.6652. *)
  let near x y tol = Float.abs (x -. y) < tol in
  near (normal_var ~confidence:0.99 ~mean:0. ~std:1.) 2.32635 1e-4
  && near (normal_es ~confidence:0.99 ~mean:0. ~std:1.) 2.66521 1e-4
  && near (normal_var ~confidence:0.95 ~mean:0. ~std:1.) 1.64485 1e-4
;;

(* Empirical VaR/ES of a large normal sample should land near the closed
   form. Fixed seed; tolerance reflects sampling error of the tail. *)
let%test "empirical estimates converge to the normal closed form" =
  let rng = Random.State.make [| 99 |] in
  let gauss () =
    let u1 = 1. -. Random.State.float rng 1. and u2 = Random.State.float rng 1. in
    sqrt (-2. *. log u1) *. cos (2. *. Float.pi *. u2)
  in
  let pnl = Array.init 200_000 (fun _ -> 3. +. (10. *. gauss ())) in
  let near x y rel = Float.abs (x -. y) < rel *. Float.abs y in
  near (var ~confidence:0.99 pnl) (normal_var ~confidence:0.99 ~mean:3. ~std:10.) 0.02
  && near
       (expected_shortfall ~confidence:0.99 pnl)
       (normal_es ~confidence:0.99 ~mean:3. ~std:10.)
       0.02
;;

let%test "rejects empty samples and bad confidence" =
  let bad f = try ignore (f ()); false with Invalid_argument _ -> true in
  bad (fun () -> var ~confidence:0.99 [||])
  && bad (fun () -> var ~confidence:1.0 [| 1. |])
  && bad (fun () -> expected_shortfall ~confidence:0. [| 1. |])
;;
