type config =
  { kind : Bs.kind
  ; spot : float
  ; strike : float
  ; rate : float
  ; drift : float
  ; implied_vol : float
  ; real_vol : float
  ; expiry : float
  ; steps : int
  }

type path_result =
  { premium : float
  ; pnl : float
  ; pnl_gamma_formula : float
  ; spots : float array
  ; deltas : float array
  }

type summary =
  { mean_pnl : float
  ; std_pnl : float
  ; paths : int
  }

let payoff kind ~strike s =
  match kind with
  | Bs.Call -> Float.max (s -. strike) 0.
  | Bs.Put -> Float.max (strike -. s) 0.
;;

let simulate cfg rng =
  if cfg.steps <= 0 then invalid_arg "Hedge.simulate: steps must be positive";
  if cfg.expiry <= 0. then invalid_arg "Hedge.simulate: expiry must be positive";
  let n = cfg.steps in
  let dt = cfg.expiry /. float_of_int n in
  let growth = exp (cfg.rate *. dt) in
  let greeks ~s ~j =
    Bs.greeks
      cfg.kind
      ~spot:s
      ~strike:cfg.strike
      ~rate:cfg.rate
      ~vol:cfg.implied_vol
      ~expiry:(cfg.expiry -. (float_of_int j *. dt))
  in
  let premium =
    Bs.price
      cfg.kind
      ~spot:cfg.spot
      ~strike:cfg.strike
      ~rate:cfg.rate
      ~vol:cfg.implied_vol
      ~expiry:cfg.expiry
  in
  let spots = Array.make (n + 1) cfg.spot in
  let deltas = Array.make n 0. in
  let delta0 = (greeks ~s:cfg.spot ~j:0).delta in
  deltas.(0) <- delta0;
  (* Sell the option, buy [delta0] shares; the rest sits in the bank. *)
  let bank = ref (premium -. (delta0 *. cfg.spot)) in
  let formula = ref 0. in
  let drift_term = (cfg.drift -. (0.5 *. cfg.real_vol *. cfg.real_vol)) *. dt in
  let vol_term = cfg.real_vol *. sqrt dt in
  for j = 0 to n - 1 do
    let s = spots.(j) in
    let s' = s *. exp (drift_term +. (vol_term *. Normal.sample rng)) in
    spots.(j + 1) <- s';
    bank := !bank *. growth;
    (* Gamma term for the interval [j, j+1], carried to expiry. *)
    let g = (greeks ~s ~j).gamma in
    let ds = s' -. s in
    formula :=
      !formula
      +. (exp (cfg.rate *. (cfg.expiry -. (float_of_int (j + 1) *. dt)))
          *. 0.5
          *. g
          *. ((cfg.implied_vol *. cfg.implied_vol *. s *. s *. dt) -. (ds *. ds)));
    if j < n - 1
    then (
      let d' = (greeks ~s:s' ~j:(j + 1)).delta in
      bank := !bank -. ((d' -. deltas.(j)) *. s');
      deltas.(j + 1) <- d')
  done;
  let final_s = spots.(n) in
  let pnl =
    !bank
    +. (deltas.(n - 1) *. final_s)
    -. payoff cfg.kind ~strike:cfg.strike final_s
  in
  { premium; pnl; pnl_gamma_formula = !formula; spots; deltas }
;;

let summarise cfg ~seed ~paths =
  let rng = Random.State.make [| seed |] in
  let xs = Array.init paths (fun _ -> (simulate cfg rng).pnl) in
  let n = float_of_int paths in
  let mean = Array.fold_left ( +. ) 0. xs /. n in
  let var = Array.fold_left (fun a x -> a +. ((x -. mean) ** 2.)) 0. xs /. (n -. 1.) in
  { mean_pnl = mean; std_pnl = sqrt var; paths }
;;

let atm =
  { kind = Bs.Call
  ; spot = 100.
  ; strike = 100.
  ; rate = 0.05
  ; drift = 0.05
  ; implied_vol = 0.2
  ; real_vol = 0.2
  ; expiry = 1.
  ; steps = 252
  }
;;

let%test "rejects bad step counts and expiries" =
  let bad c = try ignore (simulate c (Random.State.make [| 1 |])); false with Invalid_argument _ -> true in
  bad { atm with steps = 0 } && bad { atm with expiry = 0. }
;;

let%test "same seed gives identical results" =
  summarise atm ~seed:5 ~paths:50 = summarise atm ~seed:5 ~paths:50
;;

let%test "path shapes and the stock starts at spot" =
  let r = simulate { atm with steps = 10 } (Random.State.make [| 2 |]) in
  Array.length r.spots = 11 && Array.length r.deltas = 10 && r.spots.(0) = 100.
  && Array.for_all (fun d -> d >= 0. && d <= 1.) r.deltas
;;

(* With matched vols the hedge is fair (mean PnL near zero) and the error is
   proportional to 1/sqrt(steps): quadrupling the steps should halve the
   standard deviation. Measured: std*sqrt(steps) is 6.4-7.1 from 12 to 504. *)
let%test "matched vols: fair on average and error shrinks like 1/sqrt steps" =
  let s steps = summarise { atm with steps } ~seed:1 ~paths:3000 in
  let a = s 26 and b = s 104 in
  let ratio = a.std_pnl /. b.std_pnl in
  Float.abs a.mean_pnl < 0.15 && Float.abs b.mean_pnl < 0.1 && ratio > 1.8 && ratio < 2.2
;;

(* Selling vol you then under-realise earns money, and over-realising loses.
   Measured mean PnL: +1.95 at 15% real vol, -4.02 at 30%. *)
let%test "mismatched vols: sign and size of the PnL" =
  let m rv = (summarise { atm with real_vol = rv } ~seed:7 ~paths:2000).mean_pnl in
  m 0.15 > 1.5 && m 0.30 < -3.5 && Float.abs (m 0.2) < 0.2
;;

let%test "the gamma formula tracks realised PnL path by path" =
  let cfg = { atm with real_vol = 0.3 } in
  let rng = Random.State.make [| 7 |] in
  let rs = List.init 500 (fun _ -> simulate cfg rng) in
  let n = float_of_int (List.length rs) in
  let mean f = List.fold_left (fun a r -> a +. f r) 0. rs /. n in
  let mx = mean (fun r -> r.pnl) and mf = mean (fun r -> r.pnl_gamma_formula) in
  let cov = mean (fun r -> (r.pnl -. mx) *. (r.pnl_gamma_formula -. mf)) in
  let sx = sqrt (mean (fun r -> (r.pnl -. mx) ** 2.)) in
  let sf = sqrt (mean (fun r -> (r.pnl_gamma_formula -. mf) ** 2.)) in
  cov /. (sx *. sf) > 0.97 && Float.abs (mx -. mf) < 0.3
;;
