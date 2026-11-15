type params =
  { a : float
  ; b : float
  ; rho : float
  ; m : float
  ; sigma : float
  }

let total_variance p k =
  let x = k -. p.m in
  p.a +. (p.b *. ((p.rho *. x) +. sqrt ((x *. x) +. (p.sigma *. p.sigma))))
;;

let implied_vol p ~expiry k = sqrt (Float.max 0. (total_variance p k) /. expiry)

let is_valid p =
  p.b >= 0.
  && Float.abs p.rho < 1.
  && p.sigma > 0.
  && p.a +. (p.b *. p.sigma *. sqrt (1. -. (p.rho *. p.rho))) >= 0.
;;

let min_butterfly_density p ~k_lo ~k_hi =
  let n = 400 in
  let best = ref infinity in
  for i = 0 to n do
    let k = k_lo +. ((k_hi -. k_lo) *. float_of_int i /. float_of_int n) in
    let x = k -. p.m in
    let r = sqrt ((x *. x) +. (p.sigma *. p.sigma)) in
    let w = total_variance p k in
    let w' = p.b *. (p.rho +. (x /. r)) in
    let w'' = p.b *. p.sigma *. p.sigma /. (r *. r *. r) in
    let g =
      ((1. -. (k *. w' /. (2. *. w))) ** 2.)
      -. (w' *. w' /. 4. *. ((1. /. w) +. 0.25))
      +. (w'' /. 2.)
    in
    if g < !best then best := g
  done;
  !best
;;

type point =
  { k : float
  ; w : float
  }

(* Nelder-Mead simplex minimiser. Self-contained so the library has no
   numerical dependencies. *)
let nelder_mead ~f ~start ~step ~iters =
  let n = Array.length start in
  let pts = Array.init (n + 1) (fun i ->
    let x = Array.copy start in
    if i > 0 then x.(i - 1) <- x.(i - 1) +. step.(i - 1);
    x)
  in
  let vals = Array.map f pts in
  let order () =
    let idx = Array.init (n + 1) Fun.id in
    Array.sort (fun i j -> compare vals.(i) vals.(j)) idx;
    let p = Array.map (fun i -> pts.(i)) idx and v = Array.map (fun i -> vals.(i)) idx in
    Array.blit p 0 pts 0 (n + 1);
    Array.blit v 0 vals 0 (n + 1)
  in
  let combine c x y = Array.mapi (fun i xi -> xi +. (c *. (y.(i) -. xi))) x in
  for _ = 1 to iters do
    order ();
    let centroid = Array.make n 0. in
    for i = 0 to n - 1 do
      Array.iteri (fun j x -> centroid.(j) <- centroid.(j) +. (x /. float_of_int n)) pts.(i)
    done;
    let worst = pts.(n) in
    let refl = combine (-1.) centroid worst in
    let fr = f refl in
    if fr < vals.(0)
    then (
      let exp = combine (-2.) centroid worst in
      let fe = f exp in
      if fe < fr then (pts.(n) <- exp; vals.(n) <- fe) else (pts.(n) <- refl; vals.(n) <- fr))
    else if fr < vals.(n - 1)
    then (pts.(n) <- refl; vals.(n) <- fr)
    else (
      let con = if fr < vals.(n) then combine (-0.5) centroid worst else combine 0.5 centroid worst in
      let fc = f con in
      if fc < Float.min fr vals.(n)
      then (pts.(n) <- con; vals.(n) <- fc)
      else
        for i = 1 to n do
          pts.(i) <- combine 0.5 pts.(0) pts.(i);
          vals.(i) <- f pts.(i)
        done)
  done;
  order ();
  pts.(0), vals.(0)
;;

(* Unconstrained <-> constrained: b = exp u, rho = tanh v, sigma = exp s. *)
let of_theta th =
  { a = th.(0); b = exp th.(1); rho = tanh th.(2); m = th.(3); sigma = exp th.(4) }
;;

let fit points =
  if List.length points < 5 then invalid_arg "Svi.fit: need at least 5 points";
  let pts = Array.of_list points in
  let n = float_of_int (Array.length pts) in
  let sse p =
    Array.fold_left (fun acc { k; w } -> acc +. ((total_variance p k -. w) ** 2.)) 0. pts
  in
  (* Penalise slices whose minimum variance is negative. *)
  let objective th =
    let p = of_theta th in
    let floor_ = p.a +. (p.b *. p.sigma *. sqrt (1. -. (p.rho *. p.rho))) in
    sse p +. if floor_ < 0. then 1e3 *. (floor_ ** 2.) +. 1e-3 else 0.
  in
  let w_min = Array.fold_left (fun m { w; _ } -> Float.min m w) infinity pts in
  let k_mid = Array.fold_left (fun s { k; _ } -> s +. k) 0. pts /. n in
  let starts =
    List.concat_map
      (fun rho0 ->
        List.map
          (fun sigma0 -> [| w_min *. 0.8; log 0.1; Float.atanh rho0; k_mid; log sigma0 |])
          [ 0.05; 0.2; 0.6 ])
      [ -0.7; -0.3; 0.; 0.4 ]
  in
  let best =
    List.fold_left
      (fun best start ->
        let th, v =
          nelder_mead ~f:objective ~start ~step:[| 0.02; 0.5; 0.5; 0.1; 0.5 |] ~iters:1500
        in
        (* Polish with a second, tighter pass. *)
        let th, v =
          let th2, v2 =
            nelder_mead ~f:objective ~start:th ~step:[| 0.005; 0.1; 0.1; 0.02; 0.1 |] ~iters:1500
          in
          if v2 < v then th2, v2 else th, v
        in
        match best with
        | Some (_, bv) when bv <= v -> best
        | _ -> Some (th, v))
      None
      starts
  in
  match best with
  | None -> assert false
  | Some (th, _) ->
    let p = of_theta th in
    p, sqrt (sse p /. n)
;;

let true_params = { a = 0.02; b = 0.1; rho = -0.4; m = 0.05; sigma = 0.2 }
let grid = List.init 25 (fun i -> -0.6 +. (0.05 *. float_of_int i))

let%test "valid params are accepted, invalid rejected" =
  is_valid true_params
  && (not (is_valid { true_params with b = -0.1 }))
  && (not (is_valid { true_params with rho = 1.2 }))
  && (not (is_valid { true_params with sigma = 0. }))
  && not (is_valid { true_params with a = -1. })
;;

let%test "fit recovers noiseless SVI data to high accuracy" =
  let data = List.map (fun k -> { k; w = total_variance true_params k }) grid in
  let p, rmse = fit data in
  rmse < 1e-6
  && List.for_all
       (fun k -> Float.abs (total_variance p k -. total_variance true_params k) < 1e-5)
       grid
;;

let%test "fit is stable under small noise" =
  let rng = Random.State.make [| 11 |] in
  let noisy =
    List.map
      (fun k ->
        let w = total_variance true_params k in
        { k; w = w *. (1. +. (0.01 *. (Random.State.float rng 2. -. 1.))) })
      grid
  in
  let p, rmse = fit noisy in
  (* 1% multiplicative noise on w ~ 0.04..0.2 bounds rmse near 1e-3. *)
  rmse < 2e-3
  && List.for_all
       (fun k ->
         Float.abs (total_variance p k -. total_variance true_params k)
         < 0.05 *. total_variance true_params k)
       grid
;;

let%test "true params satisfy the no-butterfly-arbitrage condition" =
  min_butterfly_density true_params ~k_lo:(-0.6) ~k_hi:0.6 > 0.
;;

let%test "a very steep, narrow slice violates it" =
  let bad = { a = 0.0; b = 1.5; rho = 0.95; m = 0.; sigma = 0.01 } in
  is_valid bad && min_butterfly_density bad ~k_lo:(-0.6) ~k_hi:0.6 < 0.
;;

let%test "fit needs enough points" =
  try
    ignore (fit [ { k = 0.; w = 0.04 } ]);
    false
  with
  | Invalid_argument _ -> true
;;

(* The density has a closed form at k = 0 when rho = 0 and m = 0: then
   w = a + b*sigma, w' = 0 and w'' = b/sigma, so g = 1 + b/(2 sigma).
   Taking k_lo = k_hi = 0 samples just that point. With a = 0.04, b = 0.1,
   sigma = 0.2 this is 1.25. A constant-vol slice (b = 0) has g = 1 exactly.
   Both pin down the sign and size of the second-derivative term. *)
let%test "butterfly density matches hand calculation" =
  let near x y = Float.abs (x -. y) < 1e-9 in
  let curved = { a = 0.04; b = 0.1; rho = 0.; m = 0.; sigma = 0.2 } in
  let flat = { a = 0.04; b = 0.; rho = 0.; m = 0.; sigma = 0.1 } in
  near (min_butterfly_density curved ~k_lo:0. ~k_hi:0.) 1.25
  && near (min_butterfly_density flat ~k_lo:(-0.5) ~k_hi:0.5) 1.
;;
