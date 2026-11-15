type t =
  | Buy
  | Sell

val opposite : t -> t
val to_string : t -> string

(** [+1] for [Buy], [-1] for [Sell]. Useful for signed position arithmetic. *)
val sign : t -> int
