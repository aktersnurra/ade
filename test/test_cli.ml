let ade_exe = "../bin/main.exe"

let cli_reports_version () =
  let command = Bos.Cmd.(v ade_exe % "--version") in
  match Bos.OS.Cmd.run_out command |> Bos.OS.Cmd.out_string with
  | Ok (output, _) -> Alcotest.(check string) "version" "ade 0.1.0" (String.trim output)
  | Error (`Msg message) -> Alcotest.fail message

let () =
  Alcotest.run "ade" [ "cli", [ Alcotest.test_case "version" `Quick cli_reports_version ] ]
