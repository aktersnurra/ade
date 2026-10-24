type t = { root : string }

let home () = try Sys.getenv "HOME" with Not_found -> "/tmp"

let default_root () =
  match Sys.getenv_opt "ADE_STATE_ROOT" with
  | Some root -> root
  | None -> (
      match Sys.getenv_opt "XDG_STATE_HOME" with
      | Some base -> Filename.concat base "ade"
      | None -> List.fold_left Filename.concat (home ()) [ ".local"; "state"; "ade" ])

let make ?root () =
  { root = (match root with Some root -> root | None -> default_root ()) }

let root t = t.root

let rec ensure_dir path =
  if Sys.file_exists path then
    if Sys.is_directory path then Ok ()
    else
      Error
        (Ade_error.Declaration_invalid
           { path; reason = "expected a directory but found a file" })
  else
    let parent = Filename.dirname path in
    match if parent = path then Ok () else ensure_dir parent with
    | Error _ as error -> error
    | Ok () -> (
        try
          Unix.mkdir path 0o700;
          Ok ()
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
        | Unix.Unix_error (error, _, _) ->
            Error
              (Ade_error.Declaration_invalid
                 { path; reason = Unix.error_message error }))

(* Every per-workbench path is built from a validated name, which cannot contain
   a separator or traversal, so a name can never escape the state root. *)
let workbench_dir t name =
  Filename.concat (Filename.concat t.root "workbenches") (Workbench_name.to_string name)

let lock_file t name = Filename.concat (workbench_dir t name) "lock"
let outbox_dir t name = Filename.concat (workbench_dir t name) "outbox"
let ssh_agent_file t name = Filename.concat (workbench_dir t name) "ssh-agent"
let created_file t name = Filename.concat (workbench_dir t name) "created"
let credentials_dir t name = Filename.concat (workbench_dir t name) "credentials"
let net_dir t name = Filename.concat (workbench_dir t name) "net"
let net_log t name = Filename.concat (net_dir t name) "log"
let session_allow_file t name = Filename.concat (net_dir t name) "allowed"
let proxy_pid_file t name = Filename.concat (net_dir t name) "proxy.pid"
let proxy_output_file t name = Filename.concat (net_dir t name) "proxy.out"
