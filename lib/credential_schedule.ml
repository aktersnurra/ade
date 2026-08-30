type due_decision =
  | Skip_not_running
  | Skip_healthy
  | Rotate

let decide ~now ~margin_seconds ~running ~generation =
  if not running then Skip_not_running
  else
    match generation with
    (* A running workbench with no generation needs one before any dependent
       agent starts. *)
    | None -> Rotate
    | Some generation ->
        if Credential.needs_rotation ~now ~margin_seconds generation then Rotate
        else Skip_healthy

let describe = function
  | Skip_not_running -> "workbench is not running; nothing to rotate"
  | Skip_healthy -> "current generation is healthy"
  | Rotate -> "rotation is due"

(* RunAtLoad is deliberately false: rotation should follow the interval, not
   fire every time the user logs in. There is no KeepAlive, because each
   invocation is meant to do bounded work and exit rather than linger. *)
let launchd_plist ~label ~ade_path ~interval_seconds =
  Printf.sprintf
    {|<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>%s</string>
    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
        <string>credentials</string>
        <string>rotate</string>
        <string>--due</string>
    </array>
    <key>StartInterval</key>
    <integer>%d</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
|}
    label ade_path interval_seconds
