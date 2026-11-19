# Squire

複数の AI コーディングエージェントと、ユーザー自身の仕事を横断して把握する個人用秘書です。Herdr App の右端に常駐するターミナルから操作できます。

仕事は Work Item として管理し、進捗・次のアクション・関連する Herdr ターミナルを記録します。ターミナルがない仕事も、一つの仕事に複数のターミナルが関わる場合も扱えます。

現在はコマンド式の開発版です。自然言語対話、会話履歴からの TODO 抽出、エージェントへの自動指示は未実装です。

## セットアップ

opam、SQLite 開発ライブラリ、pkg-config が必要です。Herdr 連携には Herdr App と `hc`、テストには Python 3 を使います。

リポジトリルートから実行してください。OCaml 5.4.1 と依存はリポジトリ専用の opam switch に導入します。

```sh
opam switch create . ocaml-base-compiler.5.4.1 --no-switch --no-install --yes
opam install . --deps-only --locked --yes
opam exec -- dune build @install
```

`ocaml-system.5.4.1` で作成した既存の switch を保持したい場合は、新しい作業コピーで上記を実行してください。Herdr 連携の動作確認環境は macOS、Herdr App 0.1.16、hc 0.1.21 です。

## 基本操作

まず対話画面を起動します。Herdr の右端表示を使わず、通常のターミナルでも操作できます。

```sh
opam exec -- dune exec squire -- repl
```

`squire>` にコマンドを入力します。仕事は `add` で登録するため、登録前の `list` は空です。

| コマンド例 | 操作 |
|---|---|
| `add 書類を提出する` | 仕事を登録 |
| `list` | 登録した仕事を一覧表示 |
| `show 1` | 仕事の詳細と関連を表示 |
| `update 1` | 状態・進捗メモ・次のアクションを変更 |
| `done 1` / `reopen 1` | 完了にする / 未着手に戻す |
| `sessions` | Herdr のターミナルと状態を取得 |
| `link 1 t1` | 仕事とターミナルを関連付け |
| `unlink 1 2` | 仕事の関連付けを解除 |
| `status` | 仕事と関連ターミナルの最新状態を表示 |
| `help` / `quit` | コマンド一覧 / 対話を終了 |

仕事の ID は `add` で表示された値、ターミナルのアドレスは `sessions` に出た値に置き換えてください。`unlink` の最後の数字は `show` に表示される関連番号です。`update` では項目と値を続けて入力します。

仕事の操作や状態照会は、CLI からも実行できます。

```sh
opam exec -- dune exec squire -- add '書類を提出する'
opam exec -- dune exec squire -- update 1 --status doing --next '提出先を確認する'
opam exec -- dune exec squire -- list
```

## Herdr の右端に表示する

Herdr App を開き、複製元のレイアウトを `--base-layout` で指定します。以下は標準レイアウト `main` を使う新規セットアップの例です。

```sh
opam exec -- dune exec squire -- open --base-layout main --preview
opam exec -- dune exec squire -- open --base-layout main
```

`--preview` は変更内容の表示だけを行います。適用すると、元のレイアウトを初回だけ `squire` に複製し、右端に Squire 用ターミナルを配置して切り替えます。標準 Layout・Mod は変更しません。

次回以降も初回と同じ `--base-layout` を指定してください。既に設定済みの場合は、そのときの複製元の名前を使います。起動中の Squire は再利用し、終了済みなら起動・表示を復元します。

Space / Tab を切り替えても Squire は固定表示されます。元の表示に戻すときは、Herdr で元のレイアウトを選択してください。レイアウトの切替だけでは Squire は終了しません。

Herdr App を閉じても core 上の Squire は継続します。OS 再起動後は手動で `open` を実行してください。

## データと状態の扱い

- 仕事の状態はユーザーが決める `todo / doing / waiting / done`。プログラムの `done` 報告や端末終了から、自動で仕事を完了させません
- 状態取得は `sessions` / `status` / `link` の実行時のみ。取得失敗時は、前回値があれば観測時刻と「古い情報」を付けて表示し、CLI は非ゼロで終了します。`show` は保存済みの値を表示します
- 関連付けの対象は Herdr ターミナルです。Codex / Claude の会話セッションそのものではありません
- データは `$XDG_DATA_HOME/squire/`、未設定時は `~/.local/share/squire/` に保存します。`--data-dir` で変更できます
- DB には仕事・関連付け・必要な状態メタデータを保存し、端末画面や会話本文は保存しません。LLM への送信機能はありません。接続済みリモートの状態は Herdr の既存接続を通して取得します

## 開発

```sh
opam exec -- dune build @install
opam exec -- dune runtest
opam exec -- dune build @fmt
```

自動テストは一時データと偽の外部連携を使い、本番の Herdr やユーザーデータを変更しません。開発方針は [AGENTS.md](AGENTS.md) を参照してください。

PR では Ubuntu 26.04 上で上記の 3 項目と、GitHub Actions の依存ロックを検証します。ワークフローを追加・削除したり、`uses:` を変更したりした場合は、認証済みの GitHub CLI でリポジトリルートから再生成し、ワークフローと `.github/workflows/actions.lock` の差分を確認してください。

```sh
gh extension install github/gh-actions-lock --pin v0.5.0
gh actions-lock --no-narrow
gh actions-lock --verify --no-narrow
```
