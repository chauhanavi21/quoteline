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
