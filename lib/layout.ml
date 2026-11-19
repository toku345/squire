let column_id = "squire-companion"
let terminal_id = "squire-terminal"

let terminal address =
  `Assoc
    [
      ("id", `String terminal_id);
      ("type", `String "block");
      ("content", `Assoc [ ("terminal", `String address) ]);
    ]

let column address =
  `Assoc
    [
      ("id", `String column_id);
      ("type", `String "column");
      ("size", `Assoc [ ("px", `Int 440) ]);
      ("min", `Int 320);
      ("children", `List [ terminal address ]);
    ]

let rec ids node =
  let own = match Util.member "id" node with `String s -> [ s ] | _ -> [] in
  let children =
    match Util.member "children" node with
    | `List xs -> List.concat_map ids xs
    | _ -> []
  in
  own @ children

let rec bind address node =
  if Util.member "id" node = `String terminal_id then
    if Util.member "type" node <> `String "block" then
      Util.fail "Squire の端末ノードが変更されています"
    else Util.set "content" (`Assoc [ ("terminal", `String address) ]) node
  else
    match Util.member "children" node with
    | `List children ->
        Util.set "children" (`List (List.map (bind address) children)) node
    | _ -> node

let attach address root =
  if Util.member "type" root <> `String "row" then
    Util.fail "Squire の元レイアウトは root が row である必要があります";
  let all_ids = ids root in
  if List.length all_ids <> List.length (List.sort_uniq String.compare all_ids)
  then Util.fail "レイアウトのノード ID が重複しています";
  let children = Util.member "children" root |> Util.list in
  let has_column =
    List.exists (fun c -> Util.member "id" c = `String column_id) children
  in
  if
    (not has_column)
    && (List.mem column_id all_ids || List.mem terminal_id all_ids)
  then Util.fail "Squire のノード ID と既存ノードが衝突しています";
  let children =
    if has_column then
      List.map
        (fun child ->
          if Util.member "id" child <> `String column_id then child
          else (
            if Util.member "type" child <> `String "column" then
              Util.fail "Squire 列の型が変更されています";
            let inner = Util.member "children" child |> Util.list in
            if List.mem terminal_id (ids child) then bind address child
            else
              Util.set "children" (`List (inner @ [ terminal address ])) child))
        children
    else children @ [ column address ]
  in
  Util.set "children" (`List children) root
