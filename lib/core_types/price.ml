(* Fixed-point price. Stored as an integer number of ticks so the matching
   engine never touches floating point. One tick = 1 / [ticks_per_unit]. *)

type t = int

let ticks_per_unit = 100

let of_ticks t = t
let to_ticks t = t
let of_float f = int_of_float (Float.round (f *. float_of_int ticks_per_unit))
let to_float t = float_of_int t /. float_of_int ticks_per_unit
let compare = Int.compare
let equal = Int.equal
let add = ( + )
let sub = ( - )
let to_string t = Printf.sprintf "%.2f" (to_float t)

let%expect_test "round trip" =
  print_endline (to_string (of_float 101.25));
  [%expect {| 101.25 |}]

let%expect_test "float rounding is to nearest tick" =
  print_endline (to_string (of_float 0.994));
  print_endline (to_string (of_float 0.996));
  [%expect {|
    0.99
    1.00 |}]
