let request ~git ~directory arguments =
  {
    Process_runner.executable = git;
    argv = "-C" :: directory :: arguments;
    env =
      [ ("PATH", try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin");
        ("GIT_CONFIG_GLOBAL", "/dev/null");
        ("GIT_CONFIG_SYSTEM", "/dev/null");
        ("GIT_TERMINAL_PROMPT", "0") ];
    stdin = None;
    stdio = Process_runner.Capture;
  }

let output ~runner ~git ~directory arguments = runner (request ~git ~directory arguments)

let run ~runner ~git ~directory arguments =
  match output ~runner ~git ~directory arguments with
  | Error _ as error -> error
  | Ok { Process_runner.status = 0; _ } -> Ok ()
  | Ok { Process_runner.status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = git :: arguments; status; stderr })
