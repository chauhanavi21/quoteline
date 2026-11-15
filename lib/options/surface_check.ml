type slice =
  { expiry : float
  ; params : Svi.params
  }

type violation =
  { k : float
  ; earlier : float
  ; later : float
  ; w_earlier : float
  ; w_later : float
  ; shortfall : float
  }

let calendar_violations ?(tol = 1e-9) slices ~k_lo ~k_hi ~n =
  if List.length slices < 2 then invalid_arg "Surface_check: need at least two slices";
  if n < 2 || not (k_hi > k_lo) then invalid_arg "Surface_check: bad moneyness grid";
  let slices = List.sort (fun a b -> compare a.expiry b.expiry) slices in
  let rec pairs = function
    | a :: (b :: _ as rest) -> (a, b) :: pairs rest
    | _ -> []
  in
  List.concat_map
    (fun (a, b) ->
      List.filter_map
        (fun i ->
          let k = k_lo +. ((k_hi -. k_lo) *. float_of_int i /. float_of_int (n - 1)) in
          let wa = Svi.total_variance a.params k and wb = Svi.total_variance b.params k in
          if wb < wa -. tol
          then
            Some
              { k
              ; earlier = a.expiry
              ; later = b.expiry
              ; w_earlier = wa
              ; w_later = wb
              ; shortfall = wa -. wb
              }
          else None)
        (List.init n Fun.id))
    (pairs slices)
;;

let worst_shortfall vs = List.fold_left (fun m v -> Float.max m v.shortfall) 0. vs

(* A surface built from one SVI shape with total variance scaled up with time:
   w(k, T) = T * w0(k), so w is increasing in T at every k. No violations. *)
let scaled shape t =
  { expiry = t
  ; params = { shape with Svi.a = shape.Svi.a *. t; b = shape.b *. t }
  }
;;

let shape = { Svi.a = 0.01; b = 0.1; rho = -0.4; m = 0.02; sigma = 0.2 }
let good = List.map (scaled shape) [ 0.1; 0.25; 0.5; 1.0; 2.0 ]

let%test "a surface whose variance scales with time passes" =
  calendar_violations good ~k_lo:(-0.6) ~k_hi:0.6 ~n:241 = []
;;

(* Break it: make the 0.5y slice carry less variance than the 0.25y slice. *)
let bad =
  List.map
    (fun s -> if s.expiry = 0.5 then { s with params = { s.params with Svi.a = 0.0001; b = 0.005 } } else s)
    good
;;

let%test "a slice with less variance than an earlier one is flagged" =
  let vs = calendar_violations bad ~k_lo:(-0.6) ~k_hi:0.6 ~n:241 in
  vs <> []
  && List.for_all (fun v -> v.shortfall > 0. && v.later > v.earlier) vs
  && List.exists (fun v -> v.earlier = 0.25 && v.later = 0.5) vs
;;

let%test "input order does not matter" =
  calendar_violations (List.rev bad) ~k_lo:(-0.6) ~k_hi:0.6 ~n:241
  = calendar_violations bad ~k_lo:(-0.6) ~k_hi:0.6 ~n:241
;;

(* At k = m both slices reduce to w = a + b*sigma (the rho term vanishes and
   sqrt (0 + sigma^2) = sigma). Slice 1: 0.04 + 0.1*0.2 = 0.06. Slice 2:
   0.02 + 0.1*0.2 = 0.04. The shortfall is 0.02. A grid of three points
   straddling m = 0 puts one sample exactly there. *)
let%test "hand-checked shortfall of 0.02 at k = m" =
  let p a = { Svi.a; b = 0.1; rho = 0.3; m = 0.; sigma = 0.2 } in
  let vs =
    calendar_violations
      [ { expiry = 1.; params = p 0.04 }; { expiry = 2.; params = p 0.02 } ]
      ~k_lo:(-1e-12) ~k_hi:1e-12 ~n:3
  in
  match List.find_opt (fun v -> Float.abs v.k < 1e-9) vs with
  | Some v -> Float.abs (v.shortfall -. 0.02) < 1e-9 && Float.abs (worst_shortfall vs -. 0.02) < 1e-6
  | None -> false
;;

let%test "bad inputs are rejected" =
  let bad_call f = try ignore (f ()); false with Invalid_argument _ -> true in
  bad_call (fun () -> calendar_violations [ List.hd good ] ~k_lo:(-1.) ~k_hi:1. ~n:10)
  && bad_call (fun () -> calendar_violations good ~k_lo:1. ~k_hi:(-1.) ~n:10)
  && bad_call (fun () -> calendar_violations good ~k_lo:(-1.) ~k_hi:1. ~n:1)
;;
