(** Minimal JSON emitter, enough for the UI's data files.

    Non-finite floats ([nan], [infinity]) have no JSON representation and are
    written as [null], so the output always parses with [JSON.parse]. *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | List of t list
  | Object of (string * t) list

val to_string : t -> string

(** Convenience constructors. *)
val floats : float array -> t

val ints : int array -> t
val of_float_list : float list -> t
