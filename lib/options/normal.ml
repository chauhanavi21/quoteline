let pdf x = exp (-0.5 *. x *. x) /. sqrt (2. *. Float.pi)
let cdf x = 0.5 *. Float.erfc (-.x /. sqrt 2.)

let inv_cdf p =
  if not (p > 0. && p < 1.) then invalid_arg "Normal.inv_cdf: p must be in (0, 1)";
  let lo = ref (-12.) and hi = ref 12. in
  for _ = 1 to 100 do
    let mid = 0.5 *. (!lo +. !hi) in
    if cdf mid < p then lo := mid else hi := mid
  done;
  0.5 *. (!lo +. !hi)
;;

let sample rng =
  let u1 = 1. -. Random.State.float rng 1. in
  let u2 = Random.State.float rng 1. in
  sqrt (-2. *. log u1) *. cos (2. *. Float.pi *. u2)
;;

let%expect_test "known values" =
  Printf.printf "cdf(0)=%.6f cdf(1.96)=%.6f pdf(0)=%.6f\n" (cdf 0.) (cdf 1.96) (pdf 0.);
  Printf.printf
    "inv(0.975)=%.5f inv(0.99)=%.5f |inv(0.5)|<1e-12: %b\n"
    (inv_cdf 0.975)
    (inv_cdf 0.99)
    (Float.abs (inv_cdf 0.5) < 1e-12);
  [%expect {|
    cdf(0)=0.500000 cdf(1.96)=0.975002 pdf(0)=0.398942
    inv(0.975)=1.95996 inv(0.99)=2.32635 |inv(0.5)|<1e-12: true |}]
;;

let%test "inv_cdf inverts cdf" =
  List.for_all
    (fun p -> Float.abs (cdf (inv_cdf p) -. p) < 1e-12)
    [ 1e-9; 0.001; 0.05; 0.3; 0.5; 0.77; 0.99; 0.999999 ]
;;

let%test "inv_cdf rejects values outside (0, 1)" =
  List.for_all
    (fun p ->
      try
        ignore (inv_cdf p);
        false
      with
      | Invalid_argument _ -> true)
    [ 0.; 1.; -0.1; 1.5; nan ]
;;

let%test "sample has mean 0, variance 1 and the right tail" =
  let rng = Random.State.make [| 3 |] in
  let n = 200_000 in
  let xs = Array.init n (fun _ -> sample rng) in
  let mean = Array.fold_left ( +. ) 0. xs /. float_of_int n in
  let var = Array.fold_left (fun a x -> a +. ((x -. mean) ** 2.)) 0. xs /. float_of_int n in
  let tail = float_of_int (Array.fold_left (fun a x -> if x > 1.96 then a + 1 else a) 0 xs) /. float_of_int n in
  Float.abs mean < 0.01 && Float.abs (var -. 1.) < 0.02 && Float.abs (tail -. 0.025) < 0.002
;;
