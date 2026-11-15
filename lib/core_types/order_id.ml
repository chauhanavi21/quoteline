type t = int

let of_int n = n
let to_int t = t
let compare = Int.compare
let equal = Int.equal
let to_string = string_of_int

(* Deterministic generator: ids depend only on call order, so a seeded
   simulation replays identically. *)
module Gen = struct
  type id = t
  type t = { mutable next : int }

  let create () = { next = 1 }

  let next g : id =
    let n = g.next in
    g.next <- n + 1;
    n
end

let%expect_test "generator is sequential and per-instance" =
  let g = Gen.create () and h = Gen.create () in
  let a = Gen.next g in
  let b = Gen.next g in
  let c = Gen.next h in
  Printf.printf "%s %s %s\n" (to_string a) (to_string b) (to_string c);
  [%expect {| 1 2 1 |}]
