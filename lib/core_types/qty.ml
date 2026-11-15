(* Non-negative integer quantity. [of_int] rejects negatives, so a Qty.t in
   hand is always a valid size. *)

type t = int

let zero = 0

let of_int n =
  if n < 0 then invalid_arg (Printf.sprintf "Qty.of_int: negative (%d)" n)
  else n

let to_int t = t
let compare = Int.compare
let equal = Int.equal
(* Checked: a sum that would overflow would wrap negative and break the type's
   promise, so it raises instead. *)
let add a b =
  let s = a + b in
  if s < a then invalid_arg "Qty.add: overflow" else s
;;

let is_zero t = t = 0
let min = Int.min

(* Subtraction that cannot go negative: callers must prove [b <= a]. *)
let sub a b =
  if b > a then invalid_arg "Qty.sub: would be negative" else a - b

let to_string = string_of_int

let%expect_test "sub and min" =
  print_endline (to_string (sub (of_int 10) (of_int 4)));
  print_endline (to_string (min (of_int 3) (of_int 7)));
  [%expect {|
    6
    3 |}]

let%expect_test "negative quantity is rejected" =
  (try ignore (of_int (-1)) with Invalid_argument m -> print_endline m);
  [%expect {| Qty.of_int: negative (-1) |}]

let%expect_test "add is checked against overflow" =
  print_endline (to_string (add (of_int 2) (of_int 3)));
  (try ignore (add (of_int max_int) (of_int 1)) with Invalid_argument m -> print_endline m);
  [%expect {|
    5
    Qty.add: overflow |}]
