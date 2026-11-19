open Squire
open Domain

let checks = ref 0

let check label condition =
  incr checks;
  if not condition then failwith label

let rejects label f =
  check label
    (try
       f ();
       false
     with Util.Error _ | Sqlite3.Error _ | Sqlite3.SqliteError _ -> true)

let dir () =
  let p = Filename.temp_file "squire-test-" "" in
  Sys.remove p;
  Unix.mkdir p 0o700;
  p

let terminal ?(core_id = "core-local") ?(address = "t1b") ?(created_ms = 123)
    ?(state = "live") ?(reported_status = Some "done") () =
  {
    core_id;
    terminal_id = Herdr.local_id address;
    address;
    created_ms;
    state;
    reported_status;
    app = Some "codex";
    cwd = "/work";
    where = "project / 1";
    companion = false;
    reason = None;
  }

let machine = { core_id = "core-local"; alias = "local"; state = "connected" }

let snapshot terminals =
  { observed_at = 123.; terminals; machines = [ machine ] }

let hello =
  Util.json
    {|{"generation":1,"core":{"id":"core-local"},"methods":["terminal.list"]}|}

let listing =
  Util.json
    {|{"machines":[{"id":"core-remote","name":"box","state":"connected"}],"terminals":[{"address":"box/t1b","created_ms":123,"state":"live","status":{"state":"future-state","app":"codex","msg":"do not store this"},"cwd":"/work","labels":{"where":"project / 2"},"argv":["sensitive-argument"],"title":"secret title"},{"address":"t1","created_ms":100,"state":"live","status":null,"cwd":"/work","labels":{}}]}|}

let store_tests () =
  let path = dir () in
  let db = Store.open_db path in
  let a = Store.add db "人が提出する書類" in
  let b = Store.add db "複数端末の仕事" in
  check "numeric IDs" (a.id = 1 && b.id = 2);
  rejects "empty title" (fun () -> ignore (Store.add db " "));
  ignore (Store.update db a.id ~status:Doing ~next_action:"提出先を確認" ());
  let remote = terminal ~core_id:"core-remote" ~address:"box/t2" () in
  let local = terminal () in
  Store.link db b.id local;
  Store.link db b.id remote;
  Store.link db a.id local;
  check "many to many"
    (List.length (Store.links db b.id) = 2
    && List.length (Store.links db a.id) = 1);
  Store.link db b.id local;
  check "link idempotent" (List.length (Store.links db b.id) = 2);
  let s = snapshot [ local ] in
  Store.save_snapshot db s;
  check "agent done does not complete work" ((Store.get db b.id).status = Todo);
  let app = Application.create db (fun () -> Util.fail "offline") in
  check "failure keeps timestamped cache"
    (match Application.refresh app with
    | Application.Stale (old, _) -> old.observed_at = 123.
    | _ -> false);
  rejects "stale cannot link" (fun () -> Application.link app b.id "t1b");
  check "failure preserves work state" ((Store.get db a.id).status = Doing);
  Store.exec db
    "CREATE TRIGGER fail_update BEFORE UPDATE ON work_items BEGIN SELECT \
     RAISE(ABORT,'disk failure fixture'); END";
  rejects "write fails" (fun () ->
      ignore (Store.update db a.id ~status:Done ()));
  check "failed transaction rolled back" ((Store.get db a.id).status = Doing);
  Store.exec db "DROP TRIGGER fail_update";
  ignore (Store.update db a.id ~status:Done ());
  check "explicit completion" ((Store.get db a.id).status = Done);
  ignore (Store.update db a.id ~status:Todo ());
  Store.unlink db b.id remote.core_id remote.terminal_id;
  Store.close db;
  let db = Store.open_db path in
  check "restart retains work" ((Store.get db a.id).next_action = "提出先を確認");
  check "restart retains links" (List.length (Store.links db b.id) = 1);
  check "cache roundtrip" (Store.load_snapshot db = Some s);
  check "DB private"
    ((Unix.stat (Filename.concat path "squire.sqlite")).st_perm land 0o777
    = 0o600);
  Store.close db;
  let fresh = Store.open_db (dir ()) in
  let app = Application.create fresh (fun () -> Util.fail "offline") in
  check "no cache unavailable"
    (match Application.refresh app with
    | Application.Unavailable _ -> true
    | _ -> false);
  Store.close fresh

let observation_tests () =
  let s = Herdr.decode ~observed_at:1. hello listing in
  let remote = List.hd s.terminals in
  check "remote origin core identity"
    (remote.core_id = "core-remote" && remote.terminal_id = "t1b");
  check "unknown report preserved" (remote.reported_status = Some "future-state");
  check "null report" ((List.nth s.terminals 1).reported_status = None);
  rejects "CLI compact status rejected" (fun () ->
      ignore
        (Herdr.decode ~observed_at:1. hello
           (Util.set "terminals"
              (`List
                 [
                   Util.set "status" (`String "idle")
                     (List.hd (Util.member "terminals" listing |> Util.list));
                 ])
              listing)));
  rejects "generation mismatch" (fun () ->
      ignore
        (Herdr.decode ~observed_at:1.
           (Util.set "generation" (`Int 2) hello)
           listing));
  rejects "missing method" (fun () ->
      ignore (Herdr.check_hello (Util.set "methods" (`List []) hello)));
  let link =
    {
      work_id = 1;
      core_id = remote.core_id;
      terminal_id = remote.terminal_id;
      created_ms = 123;
      address = "old-name/t1b";
    }
  in
  check "alias rename keeps link"
    (match resolve_link s link with
    | Observed t -> t.address = "box/t1b"
    | _ -> false);
  check "identity contradiction is uncertain"
    (resolve_link s { link with created_ms = 124 } = Identity_conflict);
  check "core replacement not relinked"
    (resolve_link s { link with core_id = "other-core" } = Unreachable);
  check "disconnection not finished"
    (resolve_link
       {
         s with
         machines =
           List.map
             (fun (m : machine) -> { m with state = "unreachable" })
             s.machines;
       }
       link
    = Unreachable);
  check "missing terminal retains reference"
    (resolve_link { s with terminals = [] } link = Missing);
  rejects "bad terminal id" (fun () -> ignore (Herdr.local_id "t0"));
  check "terminal control bytes escaped"
    (Util.display "\027[2J\runsafe" = " [2J unsafe")

let layout_tests () =
  let base =
    Util.json
      {|{"id":"root","type":"row","theme":"custom","children":[{"id":"sidebar","type":"block","content":{"mod":"custom-sidebar"}},{"id":"work","type":"block","content":{"tab":"active"}}]}|}
  in
  let first = Layout.attach "t1b" base in
  let children = Util.member "children" first |> Util.list in
  check "appends right column"
    (List.length children = 3
    && List.hd children = List.hd (Util.member "children" base |> Util.list));
  let column =
    List.nth children 2 |> Util.set "size" (`Assoc [ ("px", `Int 555) ])
  in
  let custom =
    Util.set "children"
      (`List [ List.nth children 0; List.nth children 1; column ])
      first
  in
  let rebound = Layout.attach "t2b" custom in
  check "rebind preserves width and siblings"
    (Util.member "size"
       (List.nth (Util.member "children" rebound |> Util.list) 2)
     = `Assoc [ ("px", `Int 555) ]
    && Util.member "theme" rebound = `String "custom");
  check "idempotent attach" (Layout.attach "t2b" rebound = rebound);
  let empty = Util.set "children" (`List []) column in
  let exited =
    Util.set "children"
      (`List [ List.nth children 0; List.nth children 1; empty ])
      first
  in
  check "restores removed terminal slot"
    (List.mem Layout.terminal_id (Layout.ids (Layout.attach "t3" exited)));
  rejects "wrong root rejected" (fun () ->
      ignore (Layout.attach "t1" (Util.set "type" (`String "column") base)))

let () =
  ignore (Unix.umask 0o077);
  store_tests ();
  observation_tests ();
  layout_tests ();
  Printf.printf "squire: %d checks passed\n" !checks
