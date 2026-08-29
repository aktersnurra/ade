let version = "ade 0.1.0"

let info = Cmdliner.Cmd.info "ade" ~version ~doc:"Manage local agent workbench VMs"

let default =
  let open Cmdliner in
  Term.(const (fun () -> `Help (`Pager, None)) $ const ())
  |> Term.ret

let command = Cmdliner.Cmd.v info default

let () = exit (Cmdliner.Cmd.eval command)
