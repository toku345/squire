type status = Todo | Doing | Waiting | Done

let status_string = function
  | Todo -> "todo"
  | Doing -> "doing"
  | Waiting -> "waiting"
  | Done -> "done"

let status_of_string = function
  | "todo" -> Todo
  | "doing" -> Doing
  | "waiting" -> Waiting
  | "done" -> Done
  | s -> Util.fail "状態は todo / doing / waiting / done から指定してください: %s" s

type work_item = {
  id : int;
  title : string;
  status : status;
  progress_note : string;
  next_action : string;
  created_at : float;
  updated_at : float;
}

type terminal = {
  core_id : string;
  terminal_id : string;
  address : string;
  created_ms : int;
  state : string;
  reported_status : string option;
  app : string option;
  cwd : string;
  where : string;
  companion : bool;
  reason : string option;
}

type machine = { core_id : string; alias : string; state : string }

type snapshot = {
  observed_at : float;
  terminals : terminal list;
  machines : machine list;
}

type terminal_link = {
  work_id : int;
  core_id : string;
  terminal_id : string;
  created_ms : int;
  address : string;
}

type link_state =
  | Observed of terminal
  | Missing
  | Unreachable
  | Identity_conflict

let resolve_link snapshot (link : terminal_link) =
  let machine =
    List.find_opt
      (fun (m : machine) -> m.core_id = link.core_id)
      snapshot.machines
  in
  match machine with
  | None -> Unreachable
  | Some m when m.state <> "connected" -> Unreachable
  | Some _ -> (
      match
        List.find_opt
          (fun (t : terminal) ->
            t.core_id = link.core_id && t.terminal_id = link.terminal_id)
          snapshot.terminals
      with
      | None -> Missing
      | Some t when t.created_ms <> link.created_ms -> Identity_conflict
      | Some t -> Observed t)
