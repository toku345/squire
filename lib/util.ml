exception Error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt
let now () = Unix.gettimeofday ()

let env name fallback =
  match Sys.getenv_opt name with Some s when s <> "" -> s | _ -> fallback ()

let home () =
  env "HOME" (fun () -> (Unix.getpwuid (Unix.getuid ())).Unix.pw_dir)

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let data_dir () =
  Filename.concat
    (env "XDG_DATA_HOME" (fun () -> Filename.concat (home ()) ".local/share"))
    "squire"

let app_home () =
  env "HERDR_APP_HOME" (fun () ->
      Filename.concat
        (env "XDG_CONFIG_HOME" (fun () -> Filename.concat (home ()) ".config"))
        "herdr-app")

let rec mkdir path =
  if not (Sys.file_exists path) then (
    mkdir (Filename.dirname path);
    try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let private_dir path =
  mkdir path;
  let st = Unix.lstat path in
  if st.Unix.st_kind <> Unix.S_DIR || st.Unix.st_uid <> Unix.getuid () then
    fail "安全なデータディレクトリではありません: %s" path;
  Unix.chmod path 0o700

let read_file path = In_channel.with_open_bin path In_channel.input_all

let json_file path =
  try Yojson.Safe.from_file path
  with Yojson.Json_error s -> fail "JSON が不正です (%s): %s" path s

let assoc = function `Assoc xs -> xs | _ -> fail "JSON object が必要です"

let member key json =
  List.assoc_opt key (assoc json) |> Option.value ~default:`Null

let string = function `String s -> s | _ -> fail "JSON string が必要です"
let list = function `List xs -> xs | _ -> fail "JSON array が必要です"

let optional_string = function
  | `String s -> Some s
  | `Null -> None
  | _ -> fail "JSON string/null が必要です"

let int = function `Int n -> n | _ -> fail "JSON integer が必要です"

let number = function
  | `Float x -> x
  | `Int n -> float_of_int n
  | _ -> fail "JSON number が必要です"

let set key value json =
  let fields = assoc json in
  `Assoc
    (if List.mem_assoc key fields then
       List.map (fun (k, v) -> (k, if k = key then value else v)) fields
     else fields @ [ (key, value) ])

let json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> fail "JSON 応答が不正です: %s" e

let atomic_write path text =
  let temp, channel =
    Filename.open_temp_file ~temp_dir:(Filename.dirname path) ".squire-" ".tmp"
  in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr channel;
      if Sys.file_exists temp then Sys.remove temp)
    (fun () ->
      output_string channel text;
      flush channel;
      Unix.fsync (Unix.descr_of_out_channel channel);
      close_out channel;
      Unix.rename temp path)

let with_lock path f =
  let fd =
    Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      (try Unix.lockf fd Unix.F_TLOCK 0
       with Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
         fail "別の Squire 操作が実行中です");
      f ())

(* Terminal control bytes from external metadata must not become UI commands. *)
let display s =
  String.map
    (fun c -> if Char.code c < 32 || Char.code c = 127 then ' ' else c)
    s

let nonempty field s =
  let s = String.trim s in
  if s = "" then fail "%s は空にできません" field;
  s

let timestamp t =
  let d = Unix.localtime t in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (d.tm_year + 1900)
    (d.tm_mon + 1) d.tm_mday d.tm_hour d.tm_min d.tm_sec
