type binding = { port : int; token : string; proxy : Unix.sockaddr }

let address binding = Printf.sprintf "127.0.0.1:%d" binding.port
let token_hex binding =
  String.concat "" (List.init 32 (fun i -> Printf.sprintf "%02x" (Char.code binding.token.[i])))

let endpoint proxy =
  let colon = String.rindex proxy ':' in
  let ip = Unix.inet_addr_of_string (String.sub proxy 0 colon) in
  let port = int_of_string (String.sub proxy (colon + 1) (String.length proxy - colon - 1)) in
  if port <= 0 || port > 65535 then invalid_arg "proxy port";
  Unix.ADDR_INET (ip, port)

let load file =
  try
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_file file in
    let address = member "address" json |> to_string |> endpoint in
    let port =
      match address with
      | Unix.ADDR_INET (ip, port) when ip = Unix.inet_addr_loopback -> port
      | _ -> invalid_arg "guard must bind loopback"
    in
    let hex = member "token" json |> to_string in
    if String.length hex <> 64
       || not (String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) hex)
    then invalid_arg "guard token";
    let token = String.init 32 (fun i -> Char.chr (int_of_string ("0x" ^ String.sub hex (i * 2) 2))) in
    let proxy = member "proxy" json |> to_string |> endpoint in
    Ok { port; token; proxy }
  with Sys_error _ | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _
     | Invalid_argument _ | Failure _ | Not_found ->
    Error "missing or invalid host egress binding; restart the workbench"

let save path binding =
  let proxy =
    match binding.proxy with
    | Unix.ADDR_INET (ip, port) -> Printf.sprintf "%s:%d" (Unix.string_of_inet_addr ip) port
    | Unix.ADDR_UNIX _ -> assert false
  in
  let json =
    `Assoc [ "address", `String (address binding); "token", `String (token_hex binding);
             "proxy", `String proxy ]
  in
  Result.map_error (fun (`Msg reason) -> reason)
    (Bos.OS.File.write ~mode:0o600 (Fpath.v path) (Yojson.Safe.to_string json))

let listen ?binding ~proxy () =
  let proxy = endpoint proxy in
  match binding with
  | Some binding when binding.proxy <> proxy ->
      Error "the proxy endpoint changed; restart the workbench"
  | _ ->
      let fd = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
      try
        Unix.setsockopt fd Unix.SO_REUSEADDR true;
        let port = match binding with Some binding -> binding.port | None -> 0 in
        Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
        Unix.listen fd 64;
        let binding =
          match binding with
          | Some binding -> binding
          | None ->
              let port = match Unix.getsockname fd with Unix.ADDR_INET (_, port) -> port | _ -> assert false in
              let token = In_channel.with_open_bin "/dev/urandom" (fun channel ->
                  match In_channel.really_input_string channel 32 with
                  | Some token -> token
                  | None -> failwith "cannot read host egress entropy") in
              { port; token; proxy }
        in
        Ok (binding, fd)
      with
      | Unix.Unix_error (error, _, _) ->
          Unix.close fd;
          Error ("cannot listen for host egress: " ^ Unix.error_message error)
      | Sys_error reason | Failure reason ->
          Unix.close fd;
          Error reason

(* SmolVM's host-only v2 wire format:
   https://github.com/smol-machines/smolvm/blob/main/crates/smolvm-protocol/src/mediated_egress.rs
   Guest bytes cannot choose the token or destination; SmolVM attests both.
   We do not interpret the bounded application payload or redirect the flow. *)
let read_exact fd length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset < length then
      match Unix.read fd bytes offset (length - offset) with
      | 0 -> raise End_of_file
      | count -> loop (offset + count)
  in
  loop 0;
  Bytes.to_string bytes

let uint16 text offset = Char.code text.[offset] * 256 + Char.code text.[offset + 1]

let permits binding fd =
  let fixed = read_exact fd 75 in
  let mismatch = ref (if String.sub fixed 0 8 = "SMOLMEG2" then 0 else 1) in
  for i = 0 to 31 do
    mismatch := !mismatch lor (Char.code fixed.[8 + i] lxor Char.code binding.token.[i])
  done;
  if !mismatch <> 0 || String.sub fixed 40 16 = String.make 16 '\000' then false
  else if fixed.[72] <> '\004' then false
  else
    let ip = read_exact fd 4 in
    let ip = Unix.inet_addr_of_string
        (String.concat "." (List.init 4 (fun i -> string_of_int (Char.code ip.[i])))) in
    let destination = Unix.ADDR_INET (ip, uint16 fixed 73) in
    let length = uint16 (read_exact fd 2) 0 in
    if length > 8192 then false
    else (
      ignore (read_exact fd length);
      destination = binding.proxy)

let handle binding fd =
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      Unix.setsockopt_float fd Unix.SO_RCVTIMEO 5.0;
      let allowed =
        try permits binding fd with End_of_file | Unix.Unix_error _ -> false
      in
      let decision = if allowed then "\000" else "\001" in
      try ignore (Unix.write_substring fd decision 0 1) with Unix.Unix_error _ -> ())

let serve binding socket =
  let rec loop () =
    match Unix.accept ~cloexec:true socket with
    | client, _ ->
        ignore (Thread.create (handle binding) client);
        loop ()
    | exception Unix.Unix_error ((Unix.EINTR | Unix.ECONNABORTED), _, _) -> loop ()
  in
  loop ()
