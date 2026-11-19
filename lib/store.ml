open Domain

type t = Sqlite3.db

let check db code =
  if not (Sqlite3.Rc.is_success code) then
    Util.fail "SQLite: %s" (Sqlite3.errmsg db)

let exec db sql = check db (Sqlite3.exec db sql)

let statement db sql values f =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
    (fun () ->
      List.iteri (fun i v -> check db (Sqlite3.bind stmt (i + 1) v)) values;
      f stmt)

let rows db sql values read =
  statement db sql values (fun stmt ->
      let rec loop acc =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW -> loop (read stmt :: acc)
        | Sqlite3.Rc.DONE -> List.rev acc
        | code ->
            check db code;
            assert false
      in
      loop [])

let write db sql values =
  statement db sql values (fun stmt -> check db (Sqlite3.step stmt))

let transaction db f =
  exec db "BEGIN IMMEDIATE";
  match f () with
  | result ->
      exec db "COMMIT";
      result
  | exception e ->
      (try exec db "ROLLBACK" with _ -> ());
      raise e

let text s = Sqlite3.Data.TEXT s
let integer n = Sqlite3.Data.INT (Int64.of_int n)
let float n = Sqlite3.Data.FLOAT n
let nullable = function None -> Sqlite3.Data.NULL | Some s -> text s
let col_s = Sqlite3.column_text
let col_i stmt i = Sqlite3.column_int stmt i
let col_f = Sqlite3.column_double

let col_opt stmt i =
  match Sqlite3.column stmt i with
  | Sqlite3.Data.NULL -> None
  | _ -> Some (col_s stmt i)

let open_db dir =
  Util.private_dir dir;
  let path = Filename.concat dir "squire.sqlite" in
  (match
     try Some (Unix.lstat path)
     with Unix.Unix_error (Unix.ENOENT, _, _) -> None
   with
  | None -> ()
  | Some st ->
      if st.Unix.st_kind <> Unix.S_REG || st.Unix.st_uid <> Unix.getuid () then
        Util.fail "安全な DB ファイルではありません: %s" path);
  let db = Sqlite3.db_open path in
  try
    Unix.chmod path 0o600;
    Sqlite3.busy_timeout db 2000;
    exec db "PRAGMA foreign_keys=ON";
    let version =
      List.hd (rows db "PRAGMA user_version" [] (fun s -> col_i s 0))
    in
    if version > 1 then Util.fail "この Squire より新しい DB です (version %d)" version;
    if version = 0 then
      transaction db (fun () ->
          exec db
            "CREATE TABLE work_items (id INTEGER PRIMARY KEY AUTOINCREMENT, \
             title TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN \
             ('todo','doing','waiting','done')), progress_note TEXT NOT NULL \
             DEFAULT '', next_action TEXT NOT NULL DEFAULT '', created_at REAL \
             NOT NULL, updated_at REAL NOT NULL)";
          exec db
            "CREATE TABLE terminal_links (work_id INTEGER NOT NULL REFERENCES \
             work_items(id), core_id TEXT NOT NULL, terminal_id TEXT NOT NULL, \
             created_ms INTEGER NOT NULL, address TEXT NOT NULL, PRIMARY \
             KEY(work_id,core_id,terminal_id))";
          exec db
            "CREATE TABLE snapshot (id INTEGER PRIMARY KEY CHECK(id=1), \
             observed_at REAL NOT NULL)";
          exec db
            "CREATE TABLE machines (core_id TEXT PRIMARY KEY, alias TEXT NOT \
             NULL, state TEXT NOT NULL)";
          exec db
            "CREATE TABLE observations (core_id TEXT NOT NULL, terminal_id \
             TEXT NOT NULL, address TEXT NOT NULL, created_ms INTEGER NOT \
             NULL, state TEXT NOT NULL, reported_status TEXT, app TEXT, cwd \
             TEXT NOT NULL, location TEXT NOT NULL, companion INTEGER NOT \
             NULL, reason TEXT, PRIMARY KEY(core_id,terminal_id))";
          exec db "PRAGMA user_version=1");
    db
  with e ->
    ignore (Sqlite3.db_close db);
    raise e

let close db = if not (Sqlite3.db_close db) then Util.fail "SQLite を閉じられませんでした"

let read_item s =
  {
    id = col_i s 0;
    title = col_s s 1;
    status = status_of_string (col_s s 2);
    progress_note = col_s s 3;
    next_action = col_s s 4;
    created_at = col_f s 5;
    updated_at = col_f s 6;
  }

let list_items db = rows db "SELECT * FROM work_items ORDER BY id" [] read_item

let get db id =
  match
    rows db "SELECT * FROM work_items WHERE id=?" [ integer id ] read_item
  with
  | [ item ] -> item
  | _ -> Util.fail "Work Item %d がありません" id

let add db title =
  let title = Util.nonempty "タイトル" title in
  let time = Util.now () in
  write db
    "INSERT INTO work_items(title,status,created_at,updated_at) \
     VALUES(?,'todo',?,?)"
    [ text title; float time; float time ];
  get db (Int64.to_int (Sqlite3.last_insert_rowid db))

let update db id ?title ?status ?progress_note ?next_action () =
  transaction db (fun () ->
      let item = get db id in
      let title =
        match title with None -> item.title | Some s -> Util.nonempty "タイトル" s
      in
      write db
        "UPDATE work_items SET \
         title=?,status=?,progress_note=?,next_action=?,updated_at=? WHERE \
         id=?"
        [
          text title;
          text (status_string (Option.value status ~default:item.status));
          text (Option.value progress_note ~default:item.progress_note);
          text (Option.value next_action ~default:item.next_action);
          float (Util.now ());
          integer id;
        ];
      get db id)

let links db work_id =
  rows db
    "SELECT work_id,core_id,terminal_id,created_ms,address FROM terminal_links \
     WHERE work_id=? ORDER BY core_id,terminal_id"
    [ integer work_id ]
    (fun s ->
      {
        work_id = col_i s 0;
        core_id = col_s s 1;
        terminal_id = col_s s 2;
        created_ms = col_i s 3;
        address = col_s s 4;
      })

let link db work_id (terminal : terminal) =
  ignore (get db work_id);
  if terminal.companion then Util.fail "Squire 自身は仕事の実行端末として関連付けできません";
  write db
    "INSERT INTO \
     terminal_links(work_id,core_id,terminal_id,created_ms,address) \
     VALUES(?,?,?,?,?) ON CONFLICT(work_id,core_id,terminal_id) DO UPDATE SET \
     created_ms=excluded.created_ms,address=excluded.address"
    [
      integer work_id;
      text terminal.core_id;
      text terminal.terminal_id;
      integer terminal.created_ms;
      text terminal.address;
    ]

let unlink db work_id core_id terminal_id =
  ignore (get db work_id);
  write db
    "DELETE FROM terminal_links WHERE work_id=? AND core_id=? AND terminal_id=?"
    [ integer work_id; text core_id; text terminal_id ];
  if Sqlite3.changes db = 0 then Util.fail "指定された関連付けがありません"

let save_snapshot db (s : snapshot) =
  transaction db (fun () ->
      exec db "DELETE FROM observations";
      exec db "DELETE FROM machines";
      List.iter
        (fun (m : machine) ->
          write db "INSERT INTO machines VALUES(?,?,?)"
            [ text m.core_id; text m.alias; text m.state ])
        s.machines;
      List.iter
        (fun (t : terminal) ->
          write db "INSERT INTO observations VALUES(?,?,?,?,?,?,?,?,?,?,?)"
            [
              text t.core_id;
              text t.terminal_id;
              text t.address;
              integer t.created_ms;
              text t.state;
              nullable t.reported_status;
              nullable t.app;
              text t.cwd;
              text t.where;
              integer (if t.companion then 1 else 0);
              nullable t.reason;
            ])
        s.terminals;
      write db
        "INSERT INTO snapshot VALUES(1,?) ON CONFLICT(id) DO UPDATE SET \
         observed_at=excluded.observed_at"
        [ float s.observed_at ])

let load_snapshot db =
  match rows db "SELECT observed_at FROM snapshot" [] (fun s -> col_f s 0) with
  | [] -> None
  | observed_at :: _ ->
      let machines =
        rows db "SELECT core_id,alias,state FROM machines" [] (fun s ->
            { core_id = col_s s 0; alias = col_s s 1; state = col_s s 2 })
      in
      let terminals =
        rows db "SELECT * FROM observations" [] (fun s ->
            {
              core_id = col_s s 0;
              terminal_id = col_s s 1;
              address = col_s s 2;
              created_ms = col_i s 3;
              state = col_s s 4;
              reported_status = col_opt s 5;
              app = col_opt s 6;
              cwd = col_s s 7;
              where = col_s s 8;
              companion = col_i s 9 = 1;
              reason = col_opt s 10;
            })
      in
      Some { observed_at; machines; terminals }
