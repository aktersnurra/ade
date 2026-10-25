type t =
  | Github_failed of Github_error.t
  | Rollback_failed of { cause : t; cleanup : t list }
  | Declaration_not_found of { path : string }
  | Declaration_invalid of { path : string; reason : string }
  | Workbench_name_invalid of { value : string; reason : string }
  | Runtime_unavailable of { executable : string }
  | Runtime_failed of { argv : string list; status : int; stderr : string }
  | Runtime_output_invalid of { context : string; reason : string }
  | Operation_refused of { operation : string; reason : string }

(* Only the executable and subcommand are rendered. Later arguments may carry
   secret-bearing values and never reach diagnostics. *)
let render_argv = function
  | [] -> "<empty command>"
  | [ executable ] -> executable
  | executable :: subcommand :: _ -> executable ^ " " ^ subcommand

let rec to_string = function
  | Github_failed error -> Github_error.to_string error
  | Rollback_failed { cause; cleanup } ->
      to_string cause ^ "; cleanup failed: " ^ String.concat "; " (List.map to_string cleanup)
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
  | Operation_refused { operation; reason } -> operation ^ " refused: " ^ reason
