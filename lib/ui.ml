open Domain

let out fmt = Printf.ksprintf (fun s -> print_endline (Util.display s)) fmt

let item (w : work_item) =
  out "#%d [%s] %s" w.id (status_string w.status) w.title;
  if w.progress_note <> "" then out "  進捗（ユーザー確定）: %s" w.progress_note;
  if w.next_action <> "" then out "  次のアクション: %s" w.next_action

let report (t : terminal) =
  Printf.sprintf "%s / プログラム報告=%s%s" t.state
    (Option.value t.reported_status ~default:"未報告")
    (match t.reason with None -> "" | Some reason -> " / reason=" ^ reason)

let terminal (t : terminal) =
  out "%s  端末=%s  %s%s" t.address (report t)
    (if t.where = "" then t.cwd else t.where)
    (if t.companion then " [Squire]" else "")

let describe_observation = function
  | Application.Fresh s ->
      out "観測: %s（今回取得）" (Util.timestamp s.observed_at);
      Some s
  | Application.Stale (s, e) ->
      out "取得不可: %s" e;
      out "前回の観測: %s（古い情報・現在の状態は不明）" (Util.timestamp s.observed_at);
      Some s
  | Application.Unavailable e ->
      out "取得不可: %s（前回の観測もありません）" e;
      None

let sessions app =
  let observation = Application.refresh app in
  Option.iter
    (fun s ->
      List.iter
        (fun (m : machine) -> out "接続先 %s: %s" m.alias m.state)
        s.machines;
      List.iter terminal s.terminals)
    (describe_observation observation);
  observation

let show_links store snapshot work_id =
  let links = Store.links store work_id in
  List.iteri
    (fun i (link : terminal_link) ->
      let label =
        match snapshot with
        | None -> "未取得"
        | Some s -> (
            match resolve_link s link with
            | Observed t -> report t
            | Missing -> "今回の一覧に存在しない（関連は保持）"
            | Unreachable -> "接続先を確認できない（関連は保持）"
            | Identity_conflict -> "識別情報が不一致・要確認（関連は保持）")
      in
      out "  関連 %d: %s [%s] core=%s" (i + 1) link.address label link.core_id)
    links

let status app =
  let observation = Application.refresh app in
  let snapshot = describe_observation observation in
  List.iter
    (fun w ->
      item w;
      show_links app.Application.store snapshot w.id)
    (Store.list_items app.store);
  observation

let succeeded = function Application.Fresh _ -> true | _ -> false

let help () =
  print_endline "add タイトル / list / show ID / update ID / done ID / reopen ID";
  print_endline
    "link ID 端末アドレス / unlink ID 関連番号 / sessions / status / help / quit";
  print_endline "登録・進捗・完了はユーザー操作だけで更新します。エージェント報告とは別です。"

let prompt text =
  print_string text;
  flush stdout;
  read_line ()

let parse_id s =
  try
    let n = int_of_string s in
    if n <= 0 then raise Exit;
    n
  with _ -> Util.fail "正の Work Item ID を指定してください"

let words s = String.split_on_char ' ' s |> List.filter (fun s -> s <> "")

let repl app =
  print_endline "Squire — 個人用の仕事メモと Herdr 状態照会";
  help ();
  List.iter item (Store.list_items app.Application.store);
  let rec loop () =
    match try Some (prompt "squire> ") with End_of_file -> None with
    | None -> ()
    | Some line ->
        let line = String.trim line in
        if line = "quit" || line = "exit" then ()
        else (
          (try
             if String.starts_with ~prefix:"add " line then
               item
                 (Store.add app.store
                    (String.sub line 4 (String.length line - 4)))
             else
               match words line with
               | [] -> ()
               | [ "help" ] -> help ()
               | [ "add" ] -> item (Store.add app.store (prompt "タイトル: "))
               | [ "list" ] -> List.iter item (Store.list_items app.store)
               | [ "show"; id ] ->
                   let id = parse_id id in
                   item (Store.get app.store id);
                   show_links app.store (Store.load_snapshot app.store) id;
                   print_endline "関連の表示は前回の観測です。最新情報は status で取得してください。"
               | [ "done"; id ] ->
                   item (Store.update app.store (parse_id id) ~status:Done ())
               | [ "reopen"; id ] ->
                   item (Store.update app.store (parse_id id) ~status:Todo ())
               | [ "update"; id ] ->
                   let id = parse_id id in
                   ignore (Store.get app.store id);
                   let field =
                     prompt "項目 (title/status/progress/next): " |> String.trim
                   in
                   let value = prompt "値: " in
                   let updated =
                     match field with
                     | "title" -> Store.update app.store id ~title:value ()
                     | "status" ->
                         Store.update app.store id
                           ~status:(status_of_string (String.trim value))
                           ()
                     | "progress" ->
                         Store.update app.store id ~progress_note:value ()
                     | "next" -> Store.update app.store id ~next_action:value ()
                     | _ -> Util.fail "項目を選んでください"
                   in
                   item updated
               | [ "sessions" ] -> ignore (sessions app)
               | [ "status" ] -> ignore (status app)
               | [ "link"; id; address ] ->
                   Application.link app (parse_id id) address;
                   print_endline "関連付けを保存しました。"
               | [ "unlink"; id; index ] -> (
                   let id = parse_id id in
                   let links = Store.links app.store id in
                   let index = parse_id index in
                   match List.nth_opt links (index - 1) with
                   | Some l ->
                       Store.unlink app.store id l.core_id l.terminal_id;
                       print_endline "関連付けを解除しました。"
                   | None -> Util.fail "show で表示される関連番号を指定してください")
               | _ -> Util.fail "コマンドを確認してください (help)"
           with
          | Util.Error e -> out "エラー: %s" e
          | Sqlite3.Error e | Sqlite3.SqliteError e -> out "DB エラー: %s" e
          | Unix.Unix_error (e, _, _) -> out "入出力エラー: %s" (Unix.error_message e)
          | End_of_file -> print_endline "入力を中断しました。");
          loop ())
  in
  loop ()
