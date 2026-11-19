type observation =
  | Fresh of Domain.snapshot
  | Stale of Domain.snapshot * string
  | Unavailable of string

type t = { store : Store.t; observe : unit -> Domain.snapshot }

let create store observe = { store; observe }

let refresh app =
  match
    try Ok (app.observe ()) with
    | Util.Error s -> Error s
    | Unix.Unix_error (e, f, _) -> Error (f ^ ": " ^ Unix.error_message e)
    | End_of_file -> Error "Herdr の接続が途中で終了しました"
  with
  | Ok s ->
      Store.save_snapshot app.store s;
      Fresh s
  | Error e -> (
      match Store.load_snapshot app.store with
      | Some s -> Stale (s, e)
      | None -> Unavailable e)

let link app work_id address =
  ignore (Store.get app.store work_id);
  match refresh app with
  | Fresh s ->
      let t = Herdr.find s address in
      Store.link app.store work_id t
  | Stale (_, e) | Unavailable e -> Util.fail "最新状態を確認できないため関連付けしません: %s" e
