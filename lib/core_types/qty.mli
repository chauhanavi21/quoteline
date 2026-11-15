(** Non-negative integer quantity. Abstract, so invalid sizes are unrepresentable. *)

type t

val zero : t

(** @raise Invalid_argument if the argument is negative. *)
val of_int : int -> t

val to_int : t -> int
val compare : t -> t -> int
val equal : t -> t -> bool
val add : t -> t -> t
val is_zero : t -> bool
val min : t -> t -> t

(** [sub a b] requires [b <= a].
    @raise Invalid_argument otherwise. *)
val sub : t -> t -> t

val to_string : t -> string
