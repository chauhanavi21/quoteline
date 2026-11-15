type t =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | List of t list
  | Object of (string * t) list

let escape buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'
;;

(* Shortest decimal that reads back to the same float, with an exponent form
   only where needed. [%.17g] always round-trips; try shorter first. *)
let float_repr f =
  let try_prec p = Printf.sprintf "%.*g" p f in
  let rec go p =
    if p >= 17
    then try_prec 17
    else (
      let s = try_prec p in
      if float_of_string s = f then s else go (p + 1))
  in
  go 1
;;

let rec write buf = function
  | Null -> Buffer.add_string buf "null"
  | Bool b -> Buffer.add_string buf (if b then "true" else "false")
  | Int i -> Buffer.add_string buf (string_of_int i)
  | Float f ->
    if Float.is_finite f then Buffer.add_string buf (float_repr f) else Buffer.add_string buf "null"
  | String s -> escape buf s
  | List xs ->
    Buffer.add_char buf '[';
    List.iteri
      (fun i x ->
        if i > 0 then Buffer.add_char buf ',';
        write buf x)
      xs;
    Buffer.add_char buf ']'
  | Object kvs ->
    Buffer.add_char buf '{';
    List.iteri
      (fun i (k, v) ->
        if i > 0 then Buffer.add_char buf ',';
        escape buf k;
        Buffer.add_char buf ':';
        write buf v)
      kvs;
    Buffer.add_char buf '}'
;;

let to_string t =
  let buf = Buffer.create 1024 in
  write buf t;
  Buffer.contents buf
;;

let floats a = List (Array.to_list (Array.map (fun f -> Float f) a))
let ints a = List (Array.to_list (Array.map (fun i -> Int i) a))
let of_float_list l = List (List.map (fun f -> Float f) l)

let%expect_test "structure and escaping" =
  print_endline
    (to_string
       (Object
          [ "a", Int 1
          ; "b", List [ Bool true; Null; String "q\"\\\n\t" ]
          ; "c", Object [ "d", Float 1.5 ]
          ; "e", List []
          ]));
  [%expect {| {"a":1,"b":[true,null,"q\"\\\n\t"],"c":{"d":1.5},"e":[]} |}]
;;

let%expect_test "non-finite floats become null; control chars are escaped" =
  print_endline (to_string (List [ Float nan; Float infinity; Float neg_infinity; Float 0. ]));
  print_endline (to_string (String "\001"));
  [%expect {|
    [null,null,null,0]
    "\u0001" |}]
;;

let%test "finite floats round-trip exactly" =
  List.for_all
    (fun f -> float_of_string (to_string (Float f)) = f)
    [ 0.1; 1. /. 3.; 123456.789; 1e-9; -2.5e17; 4.35; 1e22; Float.pi; 5e-324 ]
;;
