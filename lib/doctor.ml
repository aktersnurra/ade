type verdict = Pass | Fail | Optional_missing

type check = { name : string; verdict : verdict; detail : string }

let first_line text =
  match String.split_on_char '\n' (String.trim text) with
  | line :: _ -> line
  | [] -> ""

let probe runner executable argv =
  match
    runner
      { Process_runner.executable; argv; env = []; stdin = None; stdio = Process_runner.Capture }
  with
  | Ok { Process_runner.status = 0; stdout; _ } -> Some (first_line stdout)
  | Ok _ | Error _ -> None

let smolvm_check ~runner ~find_executable ~smolvm =
  let resolved =
    if Filename.is_implicit smolvm then find_executable smolvm else Some smolvm
  in
  match resolved with
  | None ->
      { name = "smolvm"; verdict = Fail;
        detail = "not on PATH; install it (README, Install) or set ADE_SMOLVM_BIN" }
  | Some path -> (
      match probe runner path [ "--version" ] with
      | Some version -> { name = "smolvm"; verdict = Pass; detail = path ^ " (" ^ version ^ ")" }
      | None ->
          { name = "smolvm"; verdict = Fail;
            detail = path ^ " does not answer --version" })

let tool ~find_executable ~required ~why name =
  match find_executable name with
  | Some path -> { name; verdict = Pass; detail = path }
  | None ->
      { name; verdict = (if required then Fail else Optional_missing);
        detail = "not on PATH; " ^ why }

let kvm_check ~runner ~find_executable ~kvm_usable =
  (* uname is on every host ADE supports; Sys.os_type cannot tell Linux from
     macOS. *)
  match Option.bind (find_executable "uname") (fun uname -> probe runner uname [ "-s" ]) with
  | Some "Linux" ->
      if kvm_usable () then { name = "/dev/kvm"; verdict = Pass; detail = "readable and writable" }
      else
        { name = "/dev/kvm"; verdict = Fail;
          detail = "not accessible; check the module is loaded and your user is in the kvm group" }
  | Some _ | None -> { name = "/dev/kvm"; verdict = Pass; detail = "not needed on this host" }

let run ~runner ~find_executable ~smolvm ~kvm_usable =
  [
    smolvm_check ~runner ~find_executable ~smolvm;
    kvm_check ~runner ~find_executable ~kvm_usable;
    tool ~find_executable ~required:true "git"
      ~why:"ade pull and clone mounts need it";
    tool ~find_executable ~required:false "ssh-agent"
      ~why:"needed for [ssh] mode = \"dedicated_agent\"";
    tool ~find_executable ~required:false "ssh-add"
      ~why:"needed for [ssh] mode = \"dedicated_agent\"";
    tool ~find_executable ~required:false "pass"
      ~why:"needed for pass: secret references on Linux";
  ]

(* Reading a secret is the only way to know a reference works: a keychain:
   reference on Linux, a missing pass entry or a moved key file all parse
   fine and fail at start. The value goes nowhere; only success is kept. *)
let secret_checks ~read references =
  List.map
    (fun (label, reference) ->
      match reference with
      | Error reason -> { name = label; verdict = Fail; detail = reason }
      | Ok secret -> (
          match read secret with
          | Ok () -> { name = label; verdict = Pass; detail = Secret.describe secret }
          | Error error ->
              { name = label; verdict = Fail; detail = Ade_error.to_string error }))
    references

let healthy checks = List.for_all (fun check -> check.verdict <> Fail) checks

let render check =
  let mark = match check.verdict with Pass -> "ok  " | Fail -> "FAIL" | Optional_missing -> "warn" in
  Printf.sprintf "%s  %-10s %s" mark check.name check.detail
