type target = { host : string; port : int }

let render_target { host; port } = Printf.sprintf "%s:%d" host port

(* Host names are the only thing an agent controls that reaches the log, the
   terminal and the classifier, so they are held to plain DNS syntax. That rules
   out spaces, quotes, escapes and anything else that could be read as text
   rather than a name. *)
let valid_host host =
  let length = String.length host in
  length > 0 && length <= 253
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '.' | '-' -> true | _ -> false)
       host
  && List.for_all
       (fun label ->
         let n = String.length label in
         n > 0 && n <= 63 && label.[0] <> '-' && label.[n - 1] <> '-')
       (String.split_on_char '.' host)

let normalize_host host =
  let host = String.lowercase_ascii host in
  if String.ends_with ~suffix:"." host then String.sub host 0 (String.length host - 1)
  else host

let parse_target ~default_port value =
  let host, port =
    match String.rindex_opt value ':' with
    | None -> (value, Some default_port)
    | Some colon ->
        ( String.sub value 0 colon,
          int_of_string_opt (String.sub value (colon + 1) (String.length value - colon - 1)) )
  in
  let host = normalize_host host in
  match port with
  | Some port when port > 0 && port < 65536 && valid_host host -> Ok { host; port }
  | Some _ | None -> Error (Printf.sprintf "not a host name and port: %S" value)

(* A pattern is a host, which allows the web ports, a host:port, or *.suffix,
   which allows names below the suffix but not the suffix itself. *)
type pattern = { name : string; wildcard : bool; port : int option }

let parse_pattern value =
  let wildcard = String.starts_with ~prefix:"*." value in
  let rest = if wildcard then String.sub value 2 (String.length value - 2) else value in
  let name, port =
    match String.rindex_opt rest ':' with
    | None -> (rest, None)
    | Some colon ->
        ( String.sub rest 0 colon,
          match int_of_string_opt (String.sub rest (colon + 1) (String.length rest - colon - 1)) with
          | Some port when port > 0 && port < 65536 -> Some port
          | Some _ | None -> Some 0 )
  in
  let name = normalize_host name in
  if port = Some 0 then Error (Printf.sprintf "bad port in %S" value)
  else if not (valid_host name) then Error (Printf.sprintf "not a host name: %S" value)
  else Ok { name; wildcard; port }

let web_ports = [ 443; 80 ]

let matches pattern target =
  let name_matches =
    if pattern.wildcard then String.ends_with ~suffix:("." ^ pattern.name) target.host
    else target.host = pattern.name
  in
  name_matches
  && match pattern.port with
     | Some port -> port = target.port
     | None -> List.mem target.port web_ports

let allowed patterns target = List.exists (fun pattern -> matches pattern target) patterns

type request =
  | Connect of target
  | Forward of { target : target; head : string }
      (** A plain-HTTP request, with its head rewritten for the origin server. *)

let header_end buffer =
  let rec scan i =
    if i + 3 >= String.length buffer then None
    else if String.sub buffer i 4 = "\r\n\r\n" then Some (i + 4)
    else scan (i + 1)
  in
  scan 0

(* The proxy forwards one request per connection. Keep-alive would let a
   client send a second request, to another host, down a tunnel that was only
   checked for the first, so hop-by-hop headers are dropped and the origin is
   told to close. *)
let hop_by_hop = [ "connection"; "proxy-connection"; "keep-alive"; "proxy-authorization" ]

let parse_request head =
  match String.split_on_char '\n' head with
  | [] -> Error "empty request"
  | request_line :: headers -> (
      let request_line = String.trim request_line in
      match String.split_on_char ' ' request_line with
      | [ "CONNECT"; authority; _version ] ->
          Result.map (fun target -> Connect target) (parse_target ~default_port:443 authority)
      | [ meth; uri; version ] when String.starts_with ~prefix:"http://" uri -> (
          let rest = String.sub uri 7 (String.length uri - 7) in
          let authority, path =
            match String.index_opt rest '/' with
            | Some slash -> (String.sub rest 0 slash, String.sub rest slash (String.length rest - slash))
            | None -> (rest, "/")
          in
          match parse_target ~default_port:80 authority with
          | Error _ as error -> error
          | Ok target ->
              let kept =
                List.filter_map
                  (fun line ->
                    let line = String.trim line in
                    match String.index_opt line ':' with
                    | _ when line = "" -> None
                    | Some colon
                      when List.mem
                             (String.lowercase_ascii (String.trim (String.sub line 0 colon)))
                             hop_by_hop ->
                        None
                    | _ -> Some line)
                  headers
              in
              let head =
                String.concat "\r\n"
                  ((Printf.sprintf "%s %s %s" meth path version :: kept)
                   @ [ "Connection: close"; ""; "" ])
              in
              Ok (Forward { target; head }))
      | _ -> Error "only CONNECT and absolute http:// requests are proxied")

(* Model output and anything else shown in a terminal is reduced to printable
   ASCII: a reply crafted to carry escape sequences must not be able to rewrite
   what the user sees next to the prompt to allow a host. *)
let sanitize ?(limit = 200) text =
  let printable = String.map (fun c -> if c >= ' ' && c <= '~' then c else ' ') text in
  let trimmed = String.trim printable in
  if String.length trimmed > limit then String.sub trimmed 0 limit ^ "..." else trimmed

(* Names built to carry data rather than to name a service: a raw address,
   punycode that can imitate a familiar name, a label long enough to hold an
   encoded payload, or a deep stack of labels. These go to the user without
   consulting the classifier, so no wording of the name can talk its way
   through. *)
let unusual_shape target =
  let labels = String.split_on_char '.' target.host in
  if List.for_all (fun label -> label <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) label) labels
  then Some "a raw IP address"
  else if List.exists (String.starts_with ~prefix:"xn--") labels then Some "an internationalized (punycode) name"
  else if List.exists (fun label -> String.length label > 40) labels then Some "an unusually long label"
  else if List.length labels > 6 then Some "an unusually deep name"
  else None

let blocked_response ?reason ~workbench target =
  let why =
    match reason with
    | Some reason -> Printf.sprintf "ade blocked %s: %s.\n" (render_target target) (sanitize reason)
    | None -> Printf.sprintf "ade: %s is not allowed in workbench %s.\n" (render_target target) workbench
  in
  let body =
    Printf.sprintf
      "%sNothing in this machine can allow it. Ask the user to run, on the host:\n\
      \  ade net allow %s %s\n"
      why workbench target.host
  in
  Printf.sprintf
    "HTTP/1.1 403 Blocked by ade\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\
     Connection: close\r\n\r\n%s"
    (String.length body) body

type verdict = Allow | Ask | Deny | Unavailable

let verdict_to_string = function
  | Allow -> "allow"
  | Ask -> "ask"
  | Deny -> "deny"
  | Unavailable -> "unavailable"

let verdict_of_string = function
  | "allow" -> Some Allow
  | "ask" -> Some Ask
  | "deny" -> Some Deny
  | "unavailable" -> Some Unavailable
  | _ -> None

type event =
  | Decision of { time : float; target : target; allowed : bool }
  | Classified of { time : float; host : string; verdict : verdict; reason : string }

let event_to_json = function
  | Decision { time; target; allowed } ->
      `Assoc
        [ ("time", `Float time); ("kind", `String "decision"); ("host", `String target.host);
          ("port", `Int target.port); ("allowed", `Bool allowed) ]
  | Classified { time; host; verdict; reason } ->
      `Assoc
        [ ("time", `Float time); ("kind", `String "classified"); ("host", `String host);
          ("verdict", `String (verdict_to_string verdict)); ("reason", `String reason) ]

let event_to_line event = Yojson.Safe.to_string (event_to_json event) ^ "\n"

(* The log is ADE's own file, but a line that fails to parse is skipped rather
   than fatal: a half-written last line after a crash must not hide the rest. *)
let event_of_line line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error _ -> None
  | json -> (
      let open Yojson.Safe.Util in
      try
        let time = to_number (member "time" json) in
        let host = to_string (member "host" json) in
        if not (valid_host host) then None
        else
          match to_string (member "kind" json) with
          | "decision" ->
              let port = to_int (member "port" json) in
              Some (Decision { time; target = { host; port }; allowed = to_bool (member "allowed" json) })
          | "classified" ->
              Option.map
                (fun verdict ->
                  Classified
                    { time; host; verdict; reason = sanitize (to_string (member "reason" json)) })
                (verdict_of_string (to_string (member "verdict" json)))
          | _ -> None
      with Type_error _ -> None)

let events_of_text text =
  List.filter_map
    (fun line -> if String.trim line = "" then None else event_of_line line)
    (String.split_on_char '\n' text)

type pending = {
  target : target;
  attempts : int;
  last_attempt : float;
  verdict : (verdict * string) option;
}

let pending ~allowed events =
  let latest_verdict host =
    List.fold_left
      (fun found -> function
        | Classified { host = h; verdict; reason; _ } when h = host -> Some (verdict, reason)
        | _ -> found)
      None events
  in
  let table = Hashtbl.create 16 in
  List.iter
    (function
      | Decision { time; target; allowed = false } when not (allowed target) ->
          let attempts, _ =
            Option.value (Hashtbl.find_opt table target) ~default:(0, time)
          in
          Hashtbl.replace table target (attempts + 1, time)
      | Decision _ | Classified _ -> ())
    events;
  Hashtbl.fold
    (fun target (attempts, last_attempt) acc ->
      { target; attempts; last_attempt; verdict = latest_verdict target.host } :: acc)
    table []
  |> List.sort (fun a b -> Float.compare b.last_attempt a.last_attempt)
