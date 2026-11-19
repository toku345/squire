open Domain

type t = { hc : string }

let create ?(hc = "hc") () = { hc }

let check_hello hello =
  if Util.member "generation" hello <> `Int 1 then
    Util.fail "未対応の Herdr API 世代です";
  let methods =
    Util.member "methods" hello |> Util.list |> List.map Util.string
  in
  List.iter
    (fun name ->
      if not (List.mem name methods) then Util.fail "Herdr API に %s がありません" name)
    [ "terminal.list" ];
  Util.member "core" hello |> Util.member "id" |> Util.string
  |> Util.nonempty "core ID"

let local_id address =
  let parts = String.split_on_char '/' address in
  match List.rev parts with
  | id :: _
    when String.length id >= 2
         && id.[0] = 't'
         && id.[1] >= '1'
         && id.[1] <= '9'
         && String.for_all
              (fun c -> String.contains "0123456789bcdfghjkmnpqrstvwxyz" c)
              (String.sub id 1 (String.length id - 1)) ->
      id
  | _ -> Util.fail "不正なターミナルアドレスです: %s" (Util.display address)

let decode ~observed_at hello listing =
  let core_id = check_hello hello in
  let remote =
    Util.member "machines" listing
    |> Util.list
    |> List.map (fun m ->
        {
          core_id = Util.member "id" m |> Util.string;
          alias = Util.member "name" m |> Util.string;
          state = Util.member "state" m |> Util.string;
        })
  in
  let machines = { core_id; alias = "local"; state = "connected" } :: remote in
  let terminals =
    Util.member "terminals" listing
    |> Util.list
    |> List.map (fun t ->
        let address = Util.member "address" t |> Util.string in
        let terminal_id = local_id address in
        let core_id =
          match String.split_on_char '/' address with
          | [ _ ] -> core_id
          | [ alias; _ ] -> (
              match List.find_opt (fun m -> m.alias = alias) remote with
              | Some m -> m.core_id
              | None -> Util.fail "接続先 ID が不明です: %s" (Util.display alias))
          | _ -> Util.fail "不正なターミナルアドレスです"
        in
        let status = Util.member "status" t in
        let reported_status, app =
          match status with
          | `Null -> (None, None)
          | `Assoc _ ->
              ( Some (Util.member "state" status |> Util.string),
                Util.member "app" status |> Util.optional_string )
          | _ -> Util.fail "Herdr API status は object/null である必要があります"
        in
        let labels = Util.member "labels" t in
        let label key =
          match labels with
          | `Assoc _ -> Util.member key labels |> Util.optional_string
          | _ -> None
        in
        {
          core_id;
          terminal_id;
          address;
          created_ms = Util.member "created_ms" t |> Util.int;
          state = Util.member "state" t |> Util.string;
          reported_status;
          app;
          cwd = Util.member "cwd" t |> Util.string;
          where = Option.value (label "where") ~default:"";
          companion = label "squire.role" = Some "companion";
          reason = Util.member "reason" t |> Util.optional_string;
        })
  in
  { observed_at; terminals; machines }

let observe ?(timeout = 5.) client =
  match
    Process.rpc ~timeout
      ~validate:(fun method_ result ->
        if method_ = "hello" then ignore (check_hello result))
      client.hc
      [
        ("hello", `Assoc []); ("terminal.list", `Assoc [ ("all", `Bool true) ]);
      ]
  with
  | [ hello; listing ] -> decode ~observed_at:(Util.now ()) hello listing
  | _ -> Util.fail "Herdr API 応答が不足しています"

let find snapshot address =
  match
    List.find_opt (fun (t : terminal) -> t.address = address) snapshot.terminals
  with
  | Some t
    when List.exists
           (fun (m : machine) -> m.core_id = t.core_id && m.state = "connected")
           snapshot.machines ->
      t
  | _ -> Util.fail "接続中のターミナルが見つかりません: %s" (Util.display address)
