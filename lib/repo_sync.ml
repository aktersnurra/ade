let ( let* ) = Result.bind

let refused reason = Error (Ade_error.Operation_refused { operation = "sync repositories"; reason })

let warn message = prerr_endline ("ade: warning: " ^ message)

(* [refs] fingerprints the refs a bundle was made from, so an unchanged
   repository costs one show-ref instead of a bundle of its whole history. *)
type entry = { name : string; source : string; refs : string }

let encode entries =
  Yojson.Safe.to_string
    (`Assoc
      [ ("version", `Int 1);
        ("repos", `List (List.map (fun e ->
             `Assoc [ ("name", `String e.name); ("source", `String e.source);
                      ("refs", `String e.refs) ]) entries)) ])

let decode text =
  let entry = function
    | `Assoc [ ("name", `String name); ("source", `String source); ("refs", `String refs) ] ->
        Some { name; source; refs }
    | _ -> None
  in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error reason -> Error reason
  | `Assoc [ ("version", `Int 1); ("repos", `List entries) ] -> (
      let decoded = List.filter_map entry entries in
      if List.length decoded = List.length entries then Ok decoded
      else Error "invalid repository record")
  | _ -> Error "invalid repository record"

let load ~paths name =
  let path = State_paths.repos_file paths name in
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ when not (Sys.file_exists path) -> Ok []
  | exception Sys_error reason -> refused reason
  | text -> (
      match decode text with
      | Ok entries -> Ok entries
      | Error reason ->
          Error (Ade_error.Runtime_output_invalid { context = path; reason }))

let save ~paths name entries =
  match
    Bos.OS.File.write ~mode:0o600 (Fpath.v (State_paths.repos_file paths name)) (encode entries)
  with
  | Ok () -> Ok ()
  | Error (`Msg reason) -> refused reason

let recorded ~paths name =
  let* entries = load ~paths name in
  Ok (List.map (fun e -> (e.name, e.source)) entries)

let bundle_file name = name ^ ".bundle"

(* show-ref exits 1 with no output for a repository without refs. *)
let fingerprint ~runner ~git (repo : Host_mount.repo) =
  let* output = Host_git.output ~runner ~git ~directory:repo.source [ "show-ref"; "--head" ] in
  match output with
  | { Process_runner.status = 0; stdout; _ } when stdout <> "" ->
      Ok (Some (Digestif.SHA256.(digest_string stdout |> to_hex)))
  | { Process_runner.status = 0 | 1; _ } -> Ok None
  | { Process_runner.status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = [ git; "show-ref"; "--head" ]; status; stderr })

(* The bundle is written beside its final name and renamed into place, so the
   guest never reads a half-written one. Only the host writes the inbox. *)
let bundle ~runner ~git ~inbox ~previous (repo : Host_mount.repo) refs =
  let final = Filename.concat inbox (bundle_file repo.name) in
  let unchanged =
    List.exists (fun e -> e.name = repo.name && e.source = repo.source && e.refs = refs) previous
  in
  if unchanged && Sys.file_exists final then Ok ()
  else
    let temporary = Filename.concat inbox ("." ^ bundle_file repo.name ^ ".tmp") in
    let* () =
      Host_git.run ~runner ~git ~directory:repo.source
        [ "bundle"; "create"; "--quiet"; temporary; "HEAD"; "--branches" ]
    in
    try Unix.rename temporary final; Ok ()
    with Unix.Unix_error (error, _, _) -> refused (Unix.error_message error)

let remove_stale ~inbox entries =
  let wanted = List.map (fun e -> bundle_file e.name) entries in
  try
    Array.iter
      (fun file -> if not (List.mem file wanted) then Sys.remove (Filename.concat inbox file))
      (Sys.readdir inbox);
    Ok ()
  with Sys_error reason -> refused reason

(* The name is passed as an argument, never spliced into the script. *)
let guest_script =
  {|set -eu
repo="/workspace/$1"
bundle="/inbox/$1.bundle"
if [ -e "$repo" ]; then
  exec git -C "$repo" fetch --quiet --prune --no-tags "$bundle" '+refs/heads/*:refs/remotes/host/*'
fi
exec git clone --quiet --origin host "$bundle" "$repo"|}

let sync ~smolvm ~runner ~git ~paths ~name repos =
  let inbox = State_paths.inbox_dir paths name in
  let* () = State_paths.ensure_dir inbox in
  let* previous = load ~paths name in
  let* entries =
    List.fold_left
      (fun acc (repo : Host_mount.repo) ->
        let* acc = acc in
        let* refs = fingerprint ~runner ~git repo in
        match refs with
        | None ->
            warn (Printf.sprintf "repository %s has no commits; not handed to the guest" repo.name);
            Ok acc
        | Some refs ->
            let* () = bundle ~runner ~git ~inbox ~previous repo refs in
            Ok ({ name = repo.name; source = repo.source; refs } :: acc))
      (Ok []) repos
    |> Result.map List.rev
  in
  let* () = remove_stale ~inbox entries in
  let* () = save ~paths name entries in
  List.iter
    (fun e ->
      match Smolvm.exec_checked smolvm name [ "sh"; "-c"; guest_script; "sh"; e.name ] with
      | Ok () -> ()
      | Error error ->
          warn (Printf.sprintf "repository %s was not updated in the guest: %s" e.name
                  (Ade_error.to_string error)))
    entries;
  Ok ()
