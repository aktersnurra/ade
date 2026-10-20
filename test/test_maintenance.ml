open Ade

(* Host effects are inert here: no real ssh-agent, no GitHub. Boot's own
   sequencing is tested in test_boot. *)
let services =
  {
    Boot.start_agent =
      (fun ~name:_ ~mode ~identity:_ ->
        Ok
          (Ssh_agent.of_record ~socket:"/nonexistent/agent.sock" ~pid:"0"
             ~populated:(mode = Ssh_agent.Populated)));
    stop_agent = (fun _ -> Ok ());
    install_credentials = (fun ~smolvm:_ ~name:_ _ -> Ok ());
  }

(* A fake runtime that records the exact order of operations. The ordering is
   the safety property under test: an irreversible step must never precede the
   verification that justifies it. *)
type fake = { mutable state : string; mutable calls : string list }

let verb request =
  match request.Process_runner.argv with
  | "machine" :: v :: _ -> v
  | "pack" :: v :: _ -> "pack-" ^ v
  | _ -> "?"

(* The real export helper writes an archive into the staging mount. The fake
   does the same, because validation deliberately refuses an empty export and
   a fake that wrote nothing would exercise only the refusal path. *)
let write_fake_archive request =
  let rec staging_of = function
    | "--volume" :: spec :: _ -> (
        match String.split_on_char ':' spec with host :: _ -> Some host | [] -> None)
    | _ :: rest -> staging_of rest
    | [] -> None
  in
  match staging_of request.Process_runner.argv with
  | None -> ()
  | Some host ->
      (try if not (Sys.file_exists host) then Unix.mkdir host 0o700 with Unix.Unix_error _ -> ());
      let path = Filename.concat host "workspace.tar" in
      (try
         let channel = open_out_bin path in
         output_string channel "fake workspace archive";
         close_out channel
       with Sys_error _ -> ())

let runner fake request =
  let v = verb request in
  fake.calls <- fake.calls @ [ v ];
  if v = "update" then write_fake_archive request;
  match v with
  | "status" ->
      if fake.state = "absent" then
        Ok { Process_runner.status = 1; stdout = ""; stderr = "machine 'x' not found" }
      else
        Ok
          {
            Process_runner.status = 0;
            stdout = Printf.sprintf {|{"name":"work","state":"%s"}|} fake.state;
            stderr = "";
          }
  | "create" -> fake.state <- "created"; Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  | "start" -> fake.state <- "running"; Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  | "stop" -> fake.state <- "stopped"; Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  | "delete" -> fake.state <- "absent"; Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  | _ -> Ok { Process_runner.status = 0; stdout = ""; stderr = "" }

let temp_root () =
  let p = Filename.temp_file "ade-maint-" "" in
  Sys.remove p;
  p

let setup initial =
  let fake = { state = initial; calls = [] } in
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:(runner fake) in
  (fake, smolvm, State_paths.make ~root:(temp_root ()) ())

let declaration () =
  match Declaration.load "../workbenches/work.toml" with
  | Ok d -> d
  | Error e -> Alcotest.failf "declaration: %s" (Ade_error.to_string e)

let index_of needle calls =
  let rec go i = function
    | [] -> None
    | x :: rest -> if x = needle then Some i else go (i + 1) rest
  in
  go 0 calls

(* The core reimage invariant: the old machine is never deleted before the
   export has been verified. *)
let deletion_follows_verification () =
  let fake, smolvm, paths = setup "running" in
  let _ = Maintenance.reimage ~services ~smolvm ~paths ~declaration:(declaration ()) ~force_quiesce:true in
  match (index_of "delete" fake.calls, index_of "exec" fake.calls) with
  | Some delete_at, Some export_at ->
      Alcotest.(check bool) "export precedes delete" true (export_at < delete_at)
  | None, _ -> Alcotest.fail "the old machine was never deleted"
  | _, None -> Alcotest.fail "no export was performed"

(* A completed reimage leaves the workbench stopped regardless of start state. *)
let reimage_leaves_the_workbench_stopped () =
  List.iter
    (fun initial ->
      let fake, smolvm, paths = setup initial in
      match Maintenance.reimage ~services ~smolvm ~paths ~declaration:(declaration ()) ~force_quiesce:true with
      | Ok _ -> Alcotest.(check string) ("stopped from " ^ initial) "stopped" fake.state
      | Error e -> Alcotest.failf "reimage from %s: %s" initial (Ade_error.to_string e))
    [ "running"; "stopped" ]

(* Refusing to quiesce protects running agents from losing work. *)
let reimage_refuses_running_agents_without_force () =
  let _, smolvm, paths = setup "running" in
  match Maintenance.reimage ~services ~smolvm ~paths ~declaration:(declaration ()) ~force_quiesce:false with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected a running workbench to require explicit quiescence"

(* The journal must be gone once the transaction commits, so a later command
   does not think recovery is pending. *)
let a_committed_reimage_leaves_no_journal () =
  let _, smolvm, paths = setup "stopped" in
  let d = declaration () in
  match Maintenance.reimage ~services ~smolvm ~paths ~declaration:d ~force_quiesce:true with
  | Error e -> Alcotest.failf "reimage: %s" (Ade_error.to_string e)
  | Ok _ -> (
      let journal = State_paths.journal_file paths (Declaration.name d) in
      match Reimage.read ~path:journal with
      | Ok None -> ()
      | Ok (Some j) ->
          Alcotest.failf "journal survived at phase %s" (Reimage.phase_to_string j.Reimage.phase)
      | Error e -> Alcotest.failf "journal read: %s" (Ade_error.to_string e))

(* Backup must restore whatever state it found. *)
let backup_restores_the_original_state () =
  List.iter
    (fun initial ->
      let fake, smolvm, paths = setup initial in
      match
        Maintenance.backup ~services ~smolvm ~paths ~declaration:(declaration ())
          ~destination:(temp_root ())
      with
      | Ok _ -> Alcotest.(check string) ("restored " ^ initial) initial fake.state
      | Error e -> Alcotest.failf "backup from %s: %s" initial (Ade_error.to_string e))
    [ "running"; "stopped" ]

let backup_never_deletes_the_machine () =
  let fake, smolvm, paths = setup "running" in
  let _ =
    Maintenance.backup ~services ~smolvm ~paths ~declaration:(declaration ()) ~destination:(temp_root ())
  in
  Alcotest.(check bool) "no delete" false (List.mem "delete" fake.calls)

(* Pack refuses a running source; upstream requires it stopped. *)
let pack_refuses_a_running_source () =
  let _, smolvm, _ = setup "running" in
  match Maintenance.pack ~smolvm ~declaration:(declaration ()) ~output:(temp_root ()) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected pack to refuse a running workbench"

let pack_accepts_a_stopped_source () =
  let fake, smolvm, _ = setup "stopped" in
  match Maintenance.pack ~smolvm ~declaration:(declaration ()) ~output:(temp_root ()) with
  | Ok _ -> Alcotest.(check bool) "packed" true (List.mem "pack-create" fake.calls)
  | Error e -> Alcotest.failf "pack: %s" (Ade_error.to_string e)

(* Destroy must honour the authorization decision, not bypass it. *)
let destroy_requires_authorization () =
  let fake, smolvm, paths = setup "running" in
  let name = Declaration.name (declaration ()) in
  let request = { Destroy.name; choice = Destroy.No_backup; confirmation = None } in
  match
    Maintenance.destroy ~services ~smolvm ~paths ~declaration:(declaration ()) ~request
      ~backup_destination:None
  with
  | Error _ -> Alcotest.(check bool) "not deleted" false (List.mem "delete" fake.calls)
  | Ok _ -> Alcotest.fail "expected destroy without confirmation to be refused"

let destroy_backs_up_first_when_asked () =
  let fake, smolvm, paths = setup "running" in
  let d = declaration () in
  let request =
    { Destroy.name = Declaration.name d; choice = Destroy.Backup_first;
      confirmation = Some "work" }
  in
  match
    Maintenance.destroy ~services ~smolvm ~paths ~declaration:d ~request
      ~backup_destination:(Some (temp_root ()))
  with
  | Error e -> Alcotest.failf "destroy: %s" (Ade_error.to_string e)
  | Ok _ -> (
      match (index_of "exec" fake.calls, index_of "delete" fake.calls) with
      | Some backup_at, Some delete_at ->
          Alcotest.(check bool) "backup precedes delete" true (backup_at < delete_at)
      | _, None -> Alcotest.fail "the machine was never deleted"
      | None, _ -> Alcotest.fail "no backup was taken")

let destroy_deletes_when_authorized () =
  let fake, smolvm, paths = setup "running" in
  let d = declaration () in
  let request =
    { Destroy.name = Declaration.name d; choice = Destroy.No_backup;
      confirmation = Some "work" }
  in
  match
    Maintenance.destroy ~services ~smolvm ~paths ~declaration:d ~request ~backup_destination:None
  with
  | Ok _ -> Alcotest.(check string) "absent" "absent" fake.state
  | Error e -> Alcotest.failf "destroy: %s" (Ade_error.to_string e)

let () =
  Alcotest.run "maintenance"
    [ ( "reimage",
        [ Alcotest.test_case "delete follows verify" `Quick deletion_follows_verification;
          Alcotest.test_case "leaves stopped" `Quick reimage_leaves_the_workbench_stopped;
          Alcotest.test_case "refuses running" `Quick reimage_refuses_running_agents_without_force;
          Alcotest.test_case "journal removed" `Quick a_committed_reimage_leaves_no_journal ] );
      ( "backup",
        [ Alcotest.test_case "restores state" `Quick backup_restores_the_original_state;
          Alcotest.test_case "never deletes" `Quick backup_never_deletes_the_machine ] );
      ( "pack",
        [ Alcotest.test_case "refuses running" `Quick pack_refuses_a_running_source;
          Alcotest.test_case "accepts stopped" `Quick pack_accepts_a_stopped_source ] );
      ( "destroy",
        [ Alcotest.test_case "requires authorization" `Quick destroy_requires_authorization;
          Alcotest.test_case "backs up first" `Quick destroy_backs_up_first_when_asked;
          Alcotest.test_case "deletes" `Quick destroy_deletes_when_authorized ] )
    ]
