type t =
  | Declaration_not_found of { path : string }
  | Declaration_invalid of { path : string; reason : string }
  | Workbench_name_invalid of { value : string; reason : string }
  | Runtime_unavailable of { executable : string }
  | Runtime_failed of { argv : string list; status : int; stderr : string }
  | Runtime_output_invalid of { context : string; reason : string }

(* Only the executable and subcommand are rendered. Later arguments may carry
   secret-bearing values and never reach diagnostics. *)
let render_argv = function
  | [] -> "<empty command>"
  | [ executable ] -> executable
  | executable :: subcommand :: _ -> executable ^ " " ^ subcommand

let to_string = function
  | Declaration_not_found { path } -> "no workbench declaration at " ^ path
  | Declaration_invalid { path; reason } ->
      "invalid workbench declaration at " ^ path ^ ": " ^ reason
  | Workbench_name_invalid { value; reason } ->
      "invalid workbench name " ^ Filename.quote value ^ ": " ^ reason
  | Runtime_unavailable { executable } ->
      "runtime command unavailable: " ^ executable
  | Runtime_failed { argv; status; stderr } ->
      Printf.sprintf "%s failed with status %d: %s" (render_argv argv) status
        (String.trim stderr)
  | Runtime_output_invalid { context; reason } ->
      "unreadable runtime output from " ^ context ^ ": " ^ reason
