type kind =
  | Call
  | Put

let kind_to_string = function
  | Call -> "call"
  | Put -> "put"
;;

let degenerate ~vol ~expiry = expiry <= 0. || vol <= 0.

let d1_d2 ~spot ~strike ~rate ~vol ~expiry =
  let sd = vol *. sqrt expiry in
  let d1 = (log (spot /. strike) +. ((rate +. (0.5 *. vol *. vol)) *. expiry)) /. sd in
  d1, d1 -. sd
;;

let price kind ~spot ~strike ~rate ~vol ~expiry =
  if degenerate ~vol ~expiry
  then (
    let disc_k = strike *. exp (-.rate *. Float.max expiry 0.) in
    match kind with
    | Call -> Float.max (spot -. disc_k) 0.
    | Put -> Float.max (disc_k -. spot) 0.)
  else (
    let d1, d2 = d1_d2 ~spot ~strike ~rate ~vol ~expiry in
    let disc_k = strike *. exp (-.rate *. expiry) in
    match kind with
    | Call -> (spot *. Normal.cdf d1) -. (disc_k *. Normal.cdf d2)
    | Put -> (disc_k *. Normal.cdf (-.d2)) -. (spot *. Normal.cdf (-.d1)))
;;

type greeks =
  { delta : float
  ; gamma : float
  ; vega : float
  ; theta : float
  ; rho : float
  }

let greeks kind ~spot ~strike ~rate ~vol ~expiry =
  if degenerate ~vol ~expiry
  then (
    let step =
      match kind with
      | Call -> if spot > strike then 1. else 0.
      | Put -> if spot < strike then -1. else 0.
    in
    { delta = step; gamma = 0.; vega = 0.; theta = 0.; rho = 0. })
  else (
    let d1, d2 = d1_d2 ~spot ~strike ~rate ~vol ~expiry in
    let sq = sqrt expiry in
    let disc_k = strike *. exp (-.rate *. expiry) in
    let pdf1 = Normal.pdf d1 in
    let decay = -.(spot *. pdf1 *. vol) /. (2. *. sq) in
    let gamma = pdf1 /. (spot *. vol *. sq) in
    let vega = spot *. pdf1 *. sq in
    match kind with
    | Call ->
      { delta = Normal.cdf d1
      ; gamma
      ; vega
      ; theta = decay -. (rate *. disc_k *. Normal.cdf d2)
      ; rho = expiry *. disc_k *. Normal.cdf d2
      }
    | Put ->
      { delta = Normal.cdf d1 -. 1.
      ; gamma
      ; vega
      ; theta = decay +. (rate *. disc_k *. Normal.cdf (-.d2))
      ; rho = -.expiry *. disc_k *. Normal.cdf (-.d2)
      })
;;

let%expect_test "textbook values (S=K=100, r=5%, vol=20%, T=1)" =
  (* Hand calculation: d1 = 0.35, d2 = 0.15, so call = 10.4506, put = 5.5735,
     gamma = 0.018762, vega = 37.524, call theta = -6.4140, call rho = 53.232. *)
  let p kind = price kind ~spot:100. ~strike:100. ~rate:0.05 ~vol:0.2 ~expiry:1. in
  let g kind = greeks kind ~spot:100. ~strike:100. ~rate:0.05 ~vol:0.2 ~expiry:1. in
  let c = g Call and pu = g Put in
  Printf.printf "call=%.4f put=%.4f\n" (p Call) (p Put);
  Printf.printf
    "call delta=%.4f gamma=%.5f vega=%.3f theta=%.4f rho=%.3f\n"
    c.delta
    c.gamma
    c.vega
    c.theta
    c.rho;
  Printf.printf "put  delta=%.4f theta=%.4f rho=%.3f\n" pu.delta pu.theta pu.rho;
  [%expect {|
    call=10.4506 put=5.5735
    call delta=0.6368 gamma=0.01876 vega=37.524 theta=-6.4140 rho=53.232
    put  delta=-0.3632 theta=-1.6579 rho=-41.890
    |}]
;;

let%test "put-call parity holds across a grid" =
  let spot = 100. and rate = 0.03 in
  List.for_all
    (fun (strike, vol, expiry) ->
      let c = price Call ~spot ~strike ~rate ~vol ~expiry in
      let p = price Put ~spot ~strike ~rate ~vol ~expiry in
      Float.abs (c -. p -. (spot -. (strike *. exp (-.rate *. expiry)))) < 1e-10)
    (List.concat_map
       (fun k ->
         List.concat_map
           (fun v -> List.map (fun t -> k, v, t) [ 0.05; 0.5; 2. ])
           [ 0.1; 0.4; 0.9 ])
       [ 60.; 100.; 140. ])
;;

(* Analytic Greeks against central finite differences of the price. *)
let%test "analytic greeks match finite differences" =
  let h = 1e-4 in
  let close a b = Float.abs (a -. b) < 1e-4 *. (1. +. Float.abs a) in
  List.for_all
    (fun kind ->
      List.for_all
        (fun (spot, strike, vol, expiry) ->
          let rate = 0.04 in
          let f ~spot ~vol ~expiry ~rate = price kind ~spot ~strike ~rate ~vol ~expiry in
          let g = greeks kind ~spot ~strike ~rate ~vol ~expiry in
          let delta =
            (f ~spot:(spot +. h) ~vol ~expiry ~rate -. f ~spot:(spot -. h) ~vol ~expiry ~rate)
            /. (2. *. h)
          in
          let gamma =
            (f ~spot:(spot +. h) ~vol ~expiry ~rate
             -. (2. *. f ~spot ~vol ~expiry ~rate)
             +. f ~spot:(spot -. h) ~vol ~expiry ~rate)
            /. (h *. h)
          in
          let vega =
            (f ~spot ~vol:(vol +. h) ~expiry ~rate -. f ~spot ~vol:(vol -. h) ~expiry ~rate)
            /. (2. *. h)
          in
          let theta =
            -.(f ~spot ~vol ~expiry:(expiry +. h) ~rate
               -. f ~spot ~vol ~expiry:(expiry -. h) ~rate)
            /. (2. *. h)
          in
          let rho =
            (f ~spot ~vol ~expiry ~rate:(rate +. h) -. f ~spot ~vol ~expiry ~rate:(rate -. h))
            /. (2. *. h)
          in
          close delta g.delta
          && close gamma g.gamma
          && close vega g.vega
          && close theta g.theta
          && close rho g.rho)
        [ 100., 100., 0.2, 1.; 90., 110., 0.35, 0.5; 120., 100., 0.15, 0.25 ])
    [ Call; Put ]
;;

let%test "degenerate inputs give intrinsic value" =
  price Call ~spot:110. ~strike:100. ~rate:0.05 ~vol:0.2 ~expiry:0. = 10.
  && price Put ~spot:110. ~strike:100. ~rate:0.05 ~vol:0.2 ~expiry:0. = 0.
  && (greeks Call ~spot:110. ~strike:100. ~rate:0.05 ~vol:0.2 ~expiry:0.).delta = 1.
;;
