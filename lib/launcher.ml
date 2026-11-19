type config = {
  hc : string;
  herdr_app : string;
  app_home : string;
  data_dir : string;
  executable : string;
  base_layout : string;
}

let layout_name = "squire"

let layout_path cfg name =
  Filename.concat (Filename.concat cfg.app_home "layouts") (name ^ ".json")

let binding_path cfg = Filename.concat cfg.data_dir "herdr-binding.json"

let validate cfg =
  if
    cfg.base_layout = layout_name
    || (not
          (String.for_all
             (function
               | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
               | _ -> false)
             cfg.base_layout))
    || cfg.base_layout = ""
  then Util.fail "元レイアウト名が不正です";
  if Filename.is_relative cfg.executable || not (Sys.file_exists cfg.executable)
  then Util.fail "Squire の実行ファイルが見つかりません"

let app cfg args =
  let env =
    Unix.environment () |> Array.to_list
    |> List.filter (fun s ->
        not (String.starts_with ~prefix:"HERDR_APP_HOME=" s))
  in
  let env = Array.of_list (("HERDR_APP_HOME=" ^ cfg.app_home) :: env) in
  let result = Process.run ~env cfg.herdr_app args |> Util.json in
  (match Util.member "error" result with
  | `Null -> ()
  | e -> Util.fail "Herdr App: %s" (Util.display (Yojson.Safe.to_string e)));
  result

let app_do cfg command args =
  ignore (app cfg [ "do"; command; Yojson.Safe.to_string args ])

let switch cfg name =
  app_do cfg "layout.switch" (`Assoc [ ("name", `String name) ])

let current cfg =
  let status = app cfg [ "status" ] in
  (match Util.member "errors" status with
  | `List [] -> ()
  | _ -> Util.fail "Herdr App がエラーを報告しています。status を確認してください");
  Util.member "layout" status |> Util.string

let preview cfg =
  validate cfg;
  let path =
    layout_path cfg
      (if Sys.file_exists (layout_path cfg layout_name) then layout_name
       else cfg.base_layout)
  in
  let proposed = Layout.attach "<assigned-at-open>" (Util.json_file path) in
  Printf.sprintf
    "元レイアウト: %s\n\
     専用レイアウト: %s\n\
     実行ファイル: %s\n\
     データ: %s\n\
     変更: 専用レイアウトの Squire 端末列だけを追加/更新。元レイアウトは保持。\n\
     %s\n"
    cfg.base_layout layout_name cfg.executable cfg.data_dir
    (Yojson.Safe.pretty_to_string proposed)

let expected_argv cfg =
  [ cfg.executable; "repl"; "--data-dir"; cfg.data_dir; "--hc"; cfg.hc ]

let own_terminal cfg terminal =
  let labels = Util.member "labels" terminal in
  Util.member "squire.role" labels = `String "companion"
  && Util.member "argv" terminal
     = `List (List.map (fun s -> `String s) (expected_argv cfg))
  && Util.member "keep" terminal <> `Bool true
  && Util.member "reason" terminal = `Null

let raw_list cfg =
  match
    Process.rpc
      ~validate:(fun method_ result ->
        if method_ = "hello" then ignore (Herdr.check_hello result))
      cfg.hc
      [
        ("hello", `Assoc []); ("terminal.list", `Assoc [ ("all", `Bool true) ]);
      ]
  with
  | [ hello; listing ] ->
      ignore (Herdr.check_hello hello);
      Util.member "terminals" listing |> Util.list
  | _ -> Util.fail "Herdr 端末一覧を確認できません"

let ensure_terminal cfg =
  let live_named () =
    raw_list cfg
    |> List.filter (fun t ->
        Util.member "name" t = `String "squire"
        && Util.member "state" t = `String "live"
        && not (String.contains (Util.member "address" t |> Util.string) '/'))
  in
  let existing = live_named () in
  let reuse = function
    | [ t ] when own_terminal cfg t -> Util.member "address" t |> Util.string
    | _ -> Util.fail "squire という既存端末が設定と一致しません。既存端末は変更しません"
  in
  match existing with
  | _ :: _ -> reuse existing
  | [] ->
      ignore
        (Process.run ~timeout:10. cfg.hc
           ([
              "run";
              "--bg";
              "--json";
              "--no-parent";
              "--no-notify";
              "--name";
              "squire";
              "--label";
              "squire.role=companion";
              "--";
            ]
           @ expected_argv cfg)
        |> Util.json);
      reuse (live_named ())

let check_binding cfg =
  let target_exists = Sys.file_exists (layout_path cfg layout_name) in
  if Sys.file_exists (binding_path cfg) then (
    let binding = Util.json_file (binding_path cfg) in
    if
      Util.member "app_home" binding <> `String cfg.app_home
      || Util.member "base_layout" binding <> `String cfg.base_layout
    then Util.fail "このデータディレクトリは別の Herdr レイアウト設定に関連付け済みです")
  else if target_exists then
    Util.fail "既存の squire レイアウトは Squire が作成したものと確認できません。上書きしません";
  target_exists

let open_panel cfg =
  validate cfg;
  Util.private_dir cfg.data_dir;
  Util.with_lock (Filename.concat cfg.data_dir "open.lock") (fun () ->
      let existed = check_binding cfg in
      ignore
        (Util.json_file
           (layout_path cfg (if existed then layout_name else cfg.base_layout))
        |> Layout.attach "<pending>");
      let previous = current cfg in
      try
        if not existed then (
          app_do cfg "layout.clone"
            (`Assoc
               [
                 ("name", `String cfg.base_layout); ("as", `String layout_name);
               ]);
          if not (Sys.file_exists (layout_path cfg layout_name)) then
            Util.fail "複製レイアウトを読み戻せません";
          Util.atomic_write (binding_path cfg)
            (Yojson.Safe.pretty_to_string
               (`Assoc
                  [
                    ("app_home", `String cfg.app_home);
                    ("base_layout", `String cfg.base_layout);
                  ])));
        let address = ensure_terminal cfg in
        let path = layout_path cfg layout_name in
        let before = Util.read_file path in
        let next =
          Util.json before |> Layout.attach address
          |> Yojson.Safe.pretty_to_string
        in
        if Util.read_file path <> before then
          Util.fail "レイアウトが別の操作で変更されました。再実行してください";
        (* File edits retain unrelated layout clicks; layout.set resets all clicks. *)
        if Util.json before <> Util.json next then
          Util.atomic_write path (next ^ "\n");
        switch cfg layout_name;
        if current cfg <> layout_name then Util.fail "squire レイアウトへの切替を確認できません";
        let actual = Util.json_file path in
        if Layout.attach address actual <> actual then
          Util.fail "Squire 端末設定の読み戻しが一致しません";
        address
      with e ->
        (try switch cfg previous
         with rollback ->
           Util.fail "起動に失敗し、レイアウトの復帰も失敗しました (%s / %s)" (Printexc.to_string e)
             (Printexc.to_string rollback));
        raise e)
