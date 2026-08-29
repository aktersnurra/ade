type t = string

type error =
  | Empty
  | Invalid_character of char
  | Too_long of int

(* Deliberately narrow: lowercase alphanumerics plus '-' and '_'. This keeps a
   name safe as both a SmolVM machine name and a single host path component,
   with no separators, traversal, or shell-significant characters. *)
let max_length = 64

let is_allowed = function
  | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
  | _ -> false

let of_string value =
  if String.length value = 0 then Error Empty
  else if String.length value > max_length then Error (Too_long (String.length value))
  else
    let rec scan index =
      if index >= String.length value then Ok value
      else if is_allowed value.[index] then scan (index + 1)
      else Error (Invalid_character value.[index])
    in
    scan 0

let to_string name = name

let error_reason = function
  | Empty -> "workbench name must not be empty"
  | Invalid_character c ->
      Printf.sprintf "workbench name may not contain %s"
        (Char.escaped c |> Printf.sprintf "'%s'")
  | Too_long length ->
      Printf.sprintf "workbench name is %d characters, maximum is %d" length max_length

let compare = String.compare
