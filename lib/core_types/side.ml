type t =
  | Buy
  | Sell

let opposite = function
  | Buy -> Sell
  | Sell -> Buy

let to_string = function
  | Buy -> "BUY"
  | Sell -> "SELL"

let sign = function
  | Buy -> 1
  | Sell -> -1

let%expect_test "opposite is an involution" =
  assert (opposite (opposite Buy) = Buy);
  assert (opposite (opposite Sell) = Sell);
  print_endline (to_string (opposite Buy));
  [%expect {| SELL |}]
