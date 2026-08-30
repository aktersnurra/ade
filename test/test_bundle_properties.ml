(* Property tests for archive path safety.

   Path validation is the boundary that stops a malicious workspace export from
   writing outside the restore root, so it is worth exploring with generated
   input rather than only the handful of shapes a person thinks to write. *)

open Ade

let permitted_segments = [ "src"; "lib"; ".."; "."; ""; "a"; "deep" ]

(* An independent model of the safety rule: a path is unsafe when it is
   absolute, or when replaying it ever rises above the root. A validator that
   accepted anything this model rejects would let a restore escape the
   workspace.

   The absolute case is separate from traversal: joining segments can produce a
   leading empty segment, and "/src" is absolute even though it never traverses
   upward. Hegel found exactly that shape. *)
let is_absolute path = String.length path > 0 && path.[0] = '/'

let rises_above_root path =
  let rec walk depth = function
    | [] -> false
    | ("" | ".") :: rest -> walk depth rest
    | ".." :: rest -> if depth = 0 then true else walk (depth - 1) rest
    | _ :: rest -> walk (depth + 1) rest
  in
  walk 0 (String.split_on_char '/' path)

let unsafe path = is_absolute path || rises_above_root path

let entry_of path = { Workspace_bundle.path; kind = Workspace_bundle.Regular; mode = 0o644 }

let accepted path =
  match Workspace_bundle.validate_entry ~uid:1000 ~gid:1000 (entry_of path) with
  | Ok _ -> true
  | Error _ -> false

(* Property: a relative path is accepted exactly when it never escapes the
   root. Paths are assembled from segments so that traversal is common; drawing
   arbitrary text would almost never produce an interesting "../" sequence. *)
let%hegel_test path_acceptance_matches_the_model tc =
  let segments =
    Hegel.Generators.(
      draw tc
        (lists (sampled_from permitted_segments |> Hegel.with_printer Core.String.sexp_of_t)
           ~min_size:1 ~max_size:8 ()))
  in
  let path = String.concat "/" segments in
  Hegel.note tc (Printf.sprintf "path=%S" path);
  Alcotest.(check bool) "acceptance matches model" (not (unsafe path)) (accepted path)

(* Property: no accepted path can ever resolve outside the root, however it is
   spelled. This is the invariant the restore step depends on. *)
let%hegel_test accepted_paths_never_escape tc =
  let segments =
    Hegel.Generators.(
      draw tc
        (lists (sampled_from permitted_segments |> Hegel.with_printer Core.String.sexp_of_t)
           ~min_size:1 ~max_size:10 ()))
  in
  let path = String.concat "/" segments in
  if accepted path then
    Alcotest.(check bool) "accepted path stays within root" false (unsafe path)

(* Property: validation never raises on arbitrary text. Archive entry names are
   attacker-controlled, so a crash here would be a denial of service on
   restore. *)
let%hegel_test validation_never_raises tc =
  let path = Hegel.Generators.(draw tc (text ())) in
  match Workspace_bundle.validate_entry ~uid:1000 ~gid:1000 (entry_of path) with
  | exception exn ->
      Alcotest.failf "validate_entry raised on %S: %s" path (Printexc.to_string exn)
  | Ok _ | Error _ -> ()

(* Property: an absolute path is always rejected, whatever follows the slash. *)
let%hegel_test absolute_paths_are_always_rejected tc =
  let rest = Hegel.Generators.(draw tc (text ())) in
  let path = "/" ^ rest in
  Alcotest.(check bool) "absolute rejected" false (accepted path)

let () =
  Alcotest.run "bundle_properties"
    [ ( "paths",
        [ Alcotest.test_case "matches model" `Quick path_acceptance_matches_the_model;
          Alcotest.test_case "never escapes" `Quick accepted_paths_never_escape;
          Alcotest.test_case "never raises" `Quick validation_never_raises;
          Alcotest.test_case "absolute" `Quick absolute_paths_are_always_rejected ] )
    ]
