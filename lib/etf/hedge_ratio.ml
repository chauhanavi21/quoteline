type result =
  { weights : float array
  ; residual_std : float
  ; unhedged_std : float
  ; r_squared : float
  }

(* Solve A x = b by Gaussian elimination with partial pivoting. [a] and [b] are
   consumed. Raises [Invalid_argument] on a (numerically) singular matrix. *)
let solve a b =
  let n = Array.length b in
  for col = 0 to n - 1 do
    let pivot = ref col in
    for r = col + 1 to n - 1 do
      if Float.abs a.(r).(col) > Float.abs a.(!pivot).(col) then pivot := r
    done;
    if Float.abs a.(!pivot).(col) < 1e-12
    then invalid_arg "Hedge_ratio.fit: singular system (collinear hedge instruments)";
    let tmp = a.(col) in
    a.(col) <- a.(!pivot);
    a.(!pivot) <- tmp;
    let tb = b.(col) in
    b.(col) <- b.(!pivot);
    b.(!pivot) <- tb;
    for r = col + 1 to n - 1 do
      let f = a.(r).(col) /. a.(col).(col) in
      for c = col to n - 1 do
        a.(r).(c) <- a.(r).(c) -. (f *. a.(col).(c))
      done;
      b.(r) <- b.(r) -. (f *. b.(col))
    done
  done;
  let x = Array.make n 0. in
  for r = n - 1 downto 0 do
    let s = ref b.(r) in
    for c = r + 1 to n - 1 do
      s := !s -. (a.(r).(c) *. x.(c))
    done;
    x.(r) <- !s /. a.(r).(r)
  done;
  x
;;

let std_about_zero xs =
  let n = float_of_int (Array.length xs) in
  sqrt (Array.fold_left (fun a x -> a +. (x *. x)) 0. xs /. n)
;;

let fit ~etf ~hedges =
  let m = Array.length hedges in
  let n = Array.length etf in
  if m = 0 then invalid_arg "Hedge_ratio.fit: no hedge instruments";
  if Array.exists (fun h -> Array.length h <> n) hedges
  then invalid_arg "Hedge_ratio.fit: series lengths differ";
  if n <= m then invalid_arg "Hedge_ratio.fit: need more observations than instruments";
  let xtx = Array.make_matrix m m 0. and xty = Array.make m 0. in
  for i = 0 to m - 1 do
    for j = 0 to m - 1 do
      let s = ref 0. in
      for t = 0 to n - 1 do
        s := !s +. (hedges.(i).(t) *. hedges.(j).(t))
      done;
      xtx.(i).(j) <- !s
    done;
    let s = ref 0. in
    for t = 0 to n - 1 do
      s := !s +. (hedges.(i).(t) *. etf.(t))
    done;
    xty.(i) <- !s
  done;
  let w = solve xtx xty in
  let resid =
    Array.init n (fun t ->
      let fitted = ref 0. in
      Array.iteri (fun i wi -> fitted := !fitted +. (wi *. hedges.(i).(t))) w;
      etf.(t) -. !fitted)
  in
  let residual_std = std_about_zero resid and unhedged_std = std_about_zero etf in
  { weights = w
  ; residual_std
  ; unhedged_std
  ; r_squared = 1. -. (residual_std ** 2. /. (unhedged_std ** 2.))
  }
;;

let gauss rng = Options.Normal.sample rng

let%test "recovers known weights from noiseless data" =
  let rng = Random.State.make [| 1 |] in
  let n = 500 in
  let h1 = Array.init n (fun _ -> gauss rng) and h2 = Array.init n (fun _ -> gauss rng) in
  let etf = Array.init n (fun t -> (0.7 *. h1.(t)) -. (0.2 *. h2.(t))) in
  let r = fit ~etf ~hedges:[| h1; h2 |] in
  Float.abs (r.weights.(0) -. 0.7) < 1e-9
  && Float.abs (r.weights.(1) +. 0.2) < 1e-9
  && r.residual_std < 1e-9
  && Float.abs (r.r_squared -. 1.) < 1e-9
;;

(* One instrument has a closed form: h = sum(x y) / sum(x^2). Here
   x = [1;2;3], y = [2;3;7]: h = (2+6+21)/(1+4+9) = 29/14. *)
let%test "single instrument matches the closed form" =
  let r = fit ~etf:[| 2.; 3.; 7. |] ~hedges:[| [| 1.; 2.; 3. |] |] in
  Float.abs (r.weights.(0) -. (29. /. 14.)) < 1e-12
;;

let%test "residual is orthogonal to every hedge instrument" =
  let rng = Random.State.make [| 8 |] in
  let n = 300 in
  let hs = Array.init 3 (fun _ -> Array.init n (fun _ -> gauss rng)) in
  let etf =
    Array.init n (fun t -> (0.5 *. hs.(0).(t)) +. (0.3 *. hs.(1).(t)) +. gauss rng)
  in
  let r = fit ~etf ~hedges:hs in
  let resid =
    Array.init n (fun t ->
      etf.(t) -. (r.weights.(0) *. hs.(0).(t)) -. (r.weights.(1) *. hs.(1).(t))
      -. (r.weights.(2) *. hs.(2).(t)))
  in
  Array.for_all
    (fun h ->
      let dot = ref 0. in
      Array.iteri (fun t x -> dot := !dot +. (x *. resid.(t))) h;
      Float.abs !dot < 1e-8)
    hs
;;

let%test "hedging never increases variance and adding instruments cannot hurt" =
  let rng = Random.State.make [| 21 |] in
  let n = 400 in
  let hs = Array.init 4 (fun _ -> Array.init n (fun _ -> gauss rng)) in
  let etf = Array.init n (fun t -> hs.(0).(t) +. (0.5 *. hs.(1).(t)) +. gauss rng) in
  let stds = List.map (fun m -> (fit ~etf ~hedges:(Array.sub hs 0 m)).residual_std) [ 1; 2; 3; 4 ] in
  let rec nonincreasing = function
    | a :: (b :: _ as rest) -> b <= a +. 1e-12 && nonincreasing rest
    | _ -> true
  in
  nonincreasing stds && List.hd stds <= (fit ~etf ~hedges:[| hs.(0) |]).unhedged_std +. 1e-12
;;

let%test "rejects bad shapes and collinear instruments" =
  let bad f = try ignore (f ()); false with Invalid_argument _ -> true in
  let x = [| 1.; 2.; 3.; 4. |] in
  bad (fun () -> fit ~etf:x ~hedges:[||])
  && bad (fun () -> fit ~etf:x ~hedges:[| [| 1.; 2. |] |])
  && bad (fun () -> fit ~etf:[| 1.; 2. |] ~hedges:[| [| 1.; 2. |]; [| 2.; 3. |] |])
  && bad (fun () -> fit ~etf:x ~hedges:[| x; Array.map (fun v -> 2. *. v) x |])
;;
