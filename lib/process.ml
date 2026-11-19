open Lwt.Infix

let max_output = 8 * 1024 * 1024

let read_bounded channel =
  let buffer = Buffer.create 1024 in
  let rec loop () =
    Lwt_io.read ~count:4096 channel >>= fun chunk ->
    if chunk = "" then Lwt.return (Buffer.contents buffer)
    else if Buffer.length buffer + String.length chunk > max_output then
      Lwt.fail (Util.Error "外部プロセスの応答が大きすぎます")
    else (
      Buffer.add_string buffer chunk;
      loop ())
  in
  loop ()

let with_process ?(timeout = 5.) ?env executable args f =
  let argv = Array.of_list (executable :: args) in
  Lwt_main.run
    (let p = Lwt_process.open_process_full ?env (executable, argv) in
     Lwt.finalize
       (fun () ->
         Lwt_unix.with_timeout timeout (fun () ->
             let stderr = read_bounded p#stderr in
             Lwt.both (f p) stderr >>= fun (result, errors) ->
             p#status >>= function
             | Unix.WEXITED 0 -> Lwt.return result
             | _ -> Lwt.fail (Util.Error ("外部プロセス失敗: " ^ Util.display errors))))
       (fun () ->
         (match p#state with Lwt_process.Running -> p#terminate | _ -> ());
         p#close >|= fun _ -> ()))

let run ?timeout ?env executable args =
  try
    with_process ?timeout ?env executable args (fun p ->
        Lwt_io.close p#stdin >>= fun () -> read_bounded p#stdout)
  with Lwt_unix.Timeout -> Util.fail "外部プロセスがタイムアウトしました: %s" executable

let read_line_bounded channel =
  let buffer = Buffer.create 1024 in
  let rec loop () =
    Lwt_io.read_char channel >>= fun c ->
    if c = '\n' then Lwt.return (Buffer.contents buffer)
    else if Buffer.length buffer >= max_output then
      Lwt.fail (Util.Error "JSON-RPC 応答が大きすぎます")
    else (
      Buffer.add_char buffer c;
      loop ())
  in
  loop ()

let rpc ?timeout ?(validate = fun _ _ -> ()) executable calls =
  try
    with_process ?timeout executable [ "connect" ] (fun p ->
        let rec loop id acc = function
          | [] -> Lwt_io.close p#stdin >|= fun () -> List.rev acc
          | (method_, params) :: rest ->
              let request =
                `Assoc
                  [
                    ("jsonrpc", `String "2.0");
                    ("id", `Int id);
                    ("method", `String method_);
                    ("params", params);
                  ]
              in
              Lwt_io.write_line p#stdin (Yojson.Safe.to_string request)
              >>= fun () ->
              Lwt_io.flush p#stdin >>= fun () ->
              read_line_bounded p#stdout >>= fun line ->
              let response = Util.json line in
              if
                Util.member "id" response <> `Int id
                || Util.member "jsonrpc" response <> `String "2.0"
              then Util.fail "JSON-RPC 応答 ID / version が一致しません";
              (match Util.member "error" response with
              | `Null -> ()
              | _ -> Util.fail "Herdr API エラー (%s)" method_);
              let result =
                match List.assoc_opt "result" (Util.assoc response) with
                | Some r -> r
                | None -> Util.fail "JSON-RPC result がありません"
              in
              validate method_ result;
              loop (id + 1) (result :: acc) rest
        in
        loop 1 [] calls)
  with Lwt_unix.Timeout -> Util.fail "Herdr の取得がタイムアウトしました"
