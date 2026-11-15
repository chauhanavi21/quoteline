(** Fixed-point price, stored as integer ticks. The type is abstract so a raw
    [int] quantity can never be passed where a price is expected. *)

type t

val ticks_per_unit : int
val of_ticks : int -> t
val to_ticks : t -> int
val of_float : float -> t
val to_float : t -> float
val compare : t -> t -> int
val equal : t -> t -> bool
val add : t -> t -> t
val sub : t -> t -> t
val to_string : t -> string
