open Cmdliner
open Squire

let guard f =
  try f () with
  | Util.Error e | Sys_error e | Sqlite3.Error e | Sqlite3.SqliteError e ->
      prerr_endline ("エラー: " ^ Util.display e);
      1
  | Unix.Unix_error (e, f, _) ->
      prerr_endline (f ^ ": " ^ Unix.error_message e);
      1
  | End_of_file ->
      prerr_endline "外部プロセスの応答が途中で終了しました";
      1

let data_dir =
  Arg.(
    value
    & opt string (Util.data_dir ())
    & info [ "data-dir" ] ~doc:"データディレクトリ。")

let hc = Arg.(value & opt string "hc" & info [ "hc" ] ~doc:"hc 実行ファイル。")

let id = Arg.(required & pos 0 (some int) None & info [] ~docv:"ID")

let with_store dir f =
  let db = Store.open_db dir in
  Fun.protect ~finally:(fun () -> Store.close db) (fun () -> f db)

let with_app dir hc f =
  with_store dir (fun db ->
      f (Application.create db (fun () -> Herdr.observe (Herdr.create ~hc ()))))

let local name doc term = Cmd.v (Cmd.info name ~doc) term

let list_cmd =
  local "list" "Work Item 一覧。"
    Term.(
      const (fun dir ->
          guard (fun () ->
              with_store dir (fun db -> List.iter Ui.item (Store.list_items db));
              0))
      $ data_dir)

let add_cmd =
  local "add" "Work Item を正式登録。"
    Term.(
      const (fun dir title ->
          guard (fun () ->
              with_store dir (fun db -> Ui.item (Store.add db title));
              0))
      $ data_dir
      $ Arg.(required & pos 0 (some string) None & info [] ~docv:"TITLE"))

let show_cmd =
  local "show" "Work Item と保存済みの関連を表示。"
    Term.(
      const (fun dir id ->
          guard (fun () ->
              with_store dir (fun db ->
                  Ui.item (Store.get db id);
                  Ui.show_links db (Store.load_snapshot db) id;
                  print_endline "関連の表示は前回の観測です。最新情報は status で取得してください。");
              0))
      $ data_dir $ id)

let update_cmd =
  let field names = Arg.(value & opt (some string) None & info names) in
  local "update" "指定した Work Item の項目を更新。空文字はメモをクリア。"
    Term.(
      const (fun dir id title status progress next ->
          guard (fun () ->
              if title = None && status = None && progress = None && next = None
              then Util.fail "変更する項目を指定してください";
              with_store dir (fun db ->
                  Ui.item
                    (Store.update db id ?title
                       ?status:(Option.map Domain.status_of_string status)
                       ?progress_note:progress ?next_action:next ()));
              0))
      $ data_dir $ id $ field [ "title" ] $ field [ "status" ]
      $ field [ "progress" ] $ field [ "next" ])

let state_cmd name status doc =
  local name doc
    Term.(
      const (fun dir id ->
          guard (fun () ->
              with_store dir (fun db -> Ui.item (Store.update db id ~status ()));
              0))
      $ data_dir $ id)

let observe_cmd name render =
  local name "Herdr の最新状態を照会。失敗時は前回値を明示。"
    Term.(
      const (fun dir hc ->
          guard (fun () ->
              with_app dir hc (fun app ->
                  if Ui.succeeded (render app) then 0 else 1)))
      $ data_dir $ hc)

let repl_cmd =
  local "repl" "行入力で対話。quit または EOF で終了。"
    Term.(
      const (fun dir hc ->
          guard (fun () ->
              with_app dir hc Ui.repl;
              0))
      $ data_dir $ hc)

let link_cmd =
  local "link" "現在のターミナルを明示的に関連付け。"
    Term.(
      const (fun dir hc id address ->
          guard (fun () ->
              with_app dir hc (fun app -> Application.link app id address);
              print_endline "関連付けを保存しました。";
              0))
      $ data_dir $ hc $ id
      $ Arg.(required & pos 1 (some string) None & info [] ~docv:"ADDRESS"))

let unlink_cmd =
  local "unlink" "show の関連番号を使って解除。"
    Term.(
      const (fun dir id index ->
          guard (fun () ->
              with_store dir (fun db ->
                  ignore (Store.get db id);
                  let link =
                    if index < 1 then None
                    else List.nth_opt (Store.links db id) (index - 1)
                  in
                  match link with
                  | Some l -> Store.unlink db id l.core_id l.terminal_id
                  | None -> Util.fail "関連番号がありません");
              print_endline "関連付けを解除しました。";
              0))
      $ data_dir $ id
      $ Arg.(required & pos 1 (some int) None & info [] ~docv:"LINK_NUMBER"))

let open_cmd =
  local "open" "Herdr に Squire の専用ターミナルを表示。設定を変更するので、先に --preview で確認。"
    Term.(
      const (fun dir hc app home base preview ->
          guard (fun () ->
              let cfg : Launcher.config =
                {
                  hc = (if String.contains hc '/' then Util.absolute hc else hc);
                  herdr_app = app;
                  app_home = Unix.realpath home;
                  data_dir = Util.absolute dir;
                  executable = Unix.realpath Sys.executable_name;
                  base_layout = base;
                }
              in
              if preview then print_string (Launcher.preview cfg)
              else
                Ui.out
                  "Squire を表示しました: %s (復帰: herdr-app do layout.switch \
                   '{\"name\":\"%s\"}')"
                  (Launcher.open_panel cfg) base;
              0))
      $ data_dir $ hc
      $ Arg.(value & opt string "herdr-app" & info [ "herdr-app" ])
      $ Arg.(value & opt string (Util.app_home ()) & info [ "app-home" ])
      $ Arg.(value & opt string "bottom-tabs" & info [ "base-layout" ])
      $ Arg.(value & flag & info [ "preview" ]))

let () =
  ignore (Unix.umask 0o077);
  let command =
    Cmd.group
      (Cmd.info "squire" ~version:"0.1.0"
         ~doc:"ユーザーの仕事と Herdr の状態を横断して把握する個人用秘書。")
      [
        list_cmd;
        add_cmd;
        show_cmd;
        update_cmd;
        state_cmd "done" Domain.Done "完了を明示的に確定。";
        state_cmd "reopen" Domain.Todo "todo に戻す。";
        observe_cmd "sessions" Ui.sessions;
        observe_cmd "status" Ui.status;
        repl_cmd;
        link_cmd;
        unlink_cmd;
        open_cmd;
      ]
  in
  exit (Cmd.eval' command)
