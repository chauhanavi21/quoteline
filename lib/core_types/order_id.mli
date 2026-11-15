type t

val of_int : int -> t
val to_int : t -> int
val compare : t -> t -> int
val equal : t -> t -> bool
val to_string : t -> string

(** Deterministic id generator. Two generators never share state. *)
module Gen : sig
  type id := t
  type t

  val create : unit -> t
  val next : t -> id
end
