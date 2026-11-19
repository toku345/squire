# Squire

ユーザーの仕事と、Herdr 上のエージェント・ターミナルの状態を横断して確認する個人用秘書です。

Work Item の登録・進捗・完了はユーザーが決めます。エージェントの `done` 報告やプロセス終了から、仕事を自動で完了させません。ターミナルがない仕事も管理できます。

## 現在の機能

- Work Item の登録・一覧・更新・完了・再開
- 進捗メモと次のアクションの保存
- 一つの Work Item と複数の Herdr ターミナルの関連付け
- ローカルと接続済みリモートの状態照会
- 行入力による対話と、同じ機能を呼ぶ CLI
- Herdr の専用レイアウトへの右端ターミナル配置

自然言語の解釈、候補 Inbox、会話履歴からの抽出、GitHub 同期、他エージェントへの指示は未実装です。

## 開発環境

OCaml 5.4.1、Dune 3.24.2、opam、SQLite 開発ライブラリ、pkg-config が必要です。テストには Python 3 を使います。

以下は OCaml 5.4.1 が既に PATH にある環境向けです。このリポジトリ専用の switch を作り、既存 switch の依存は変更しません。

```sh
opam switch create . ocaml-system.5.4.1 --no-switch --no-install --yes
opam install . --deps-only --locked --yes
opam exec -- dune build @install
opam exec -- dune runtest
opam exec -- dune build @fmt
```

ロックは `ocaml-system.5.4.1` を含みます。異なるコンパイラ構成や OS 向けの配布は、まだ検証していません。ドキュメント生成用の依存はロック対象外です。

日常の実行は `opam exec -- dune exec squire -- ...` を使います。`opam install .` や dotfiles への起動設定の追加は必須ではありません。

## 使い方

```sh
opam exec -- dune exec squire -- add '書類を提出する'
opam exec -- dune exec squire -- update 1 --status doing --next '提出先を確認する'
opam exec -- dune exec squire -- list
opam exec -- dune exec squire -- sessions
opam exec -- dune exec squire -- link 1 t1b
opam exec -- dune exec squire -- link 1 spark/t9
opam exec -- dune exec squire -- status
opam exec -- dune exec squire -- done 1
opam exec -- dune exec squire -- reopen 1
```

`t1b` / `spark/t9` は例です。`sessions` に出た現在のアドレスを指定してください。関連の解除は `show 1` の「関連番号」を使い、`unlink 1 2` のように指定します。

対話形式で使う場合:

```sh
opam exec -- dune exec squire -- repl
```

```text
squire> add 書類を提出する
squire> update 1
項目 (title/status/progress/next): next
値: 提出先を確認する
squire> sessions
squire> link 1 spark/t9
squire> status
squire> done 1
squire> quit
```

`update` の `progress` は進捗メモ、`next` は次のアクションです。空文字でメモを消せます。`quit` / `exit` / EOF で対話を終了します。入力の編集は端末の通常の行入力に従います。複数行エディタや入力補完はありません。

## 状態の意味

`sessions` / `status` / `link` の実行時だけ、最大5秒で Herdr に問い合わせます。定期監視や通知は行いません。

- **Work Item の状態**: ユーザーが確定した `todo / doing / waiting / done`
- **端末の状態**: core が返した `live / finished` と `reason`
- **プログラム報告**: OSC 7501 でプログラム自身が申告した状態。仕事の達成の証明ではありません
- **未報告**: プログラムが状態を申告していない場合
- **古い情報**: 取得失敗時の、時刻を付けた前回値。CLI は非ゼロで終了します

`show` に表示する関連の観測は保存済みの値です。最新情報が必要なら `status` を使います。切断・端末消失・識別情報の矛盾が起きても、仕事の状態と関連を自動で変更しません。再関連付けは、新しい状態を確認した `link` によって明示的に行います。

初期版の「関連セッション」は **Herdr ターミナル**を指します。Codex / Claude の会話セッション ID とは対応しません。同じターミナル内で会話を切り替えても、関連は端末に残ります。

## Herdr の右端に配置する

先に変更内容を確認します。このコマンドは Herdr に接続せず、設定や端末を変更しません。

```sh
opam exec -- dune exec squire -- open --preview
```

適用する場合:

```sh
opam exec -- dune exec squire -- open
```

`open` は次の操作を行います。

1. `bottom-tabs` を初回だけ Herdr の `layout.clone` で `squire` に複製し、クリックによる設定も引き継ぐ。
2. 専用名・ラベル・起動引数を照合した Squire 端末を再利用するか、親なしで新規起動する。
3. 複製レイアウトの右端に幅440px・幅変更可能な端末列を追加し、`squire` に切り替える。

元のレイアウト、標準 Mod、既存端末には変更を加えません。`squire` レイアウトは独立したコピーで、元レイアウトの後日の変更を自動で取り込みません。実ターミナルアドレスを含む生成レイアウトと、起動元を記録するデータは Git 管理しません。

既存の無関係な `squire` レイアウトや、同名の異なるプログラムを検出した場合は上書き・終了せずエラーにします。二重の `open` はプロセス終了で解放される OS ロックで防ぎます。

Space / Tab を切り替えても右列はそのままです。別レイアウトへ切り替えた場合は表示されません。クリックして入力フォーカスを移せます。

Herdr App を閉じても、core 上の Squire は継続します。Squire 自体を終了すると Herdr は端末ブロックを除去するため、次の `open` で起動・表示を復元します。OS 再起動後も手動で `open` を実行します。`--keep` によるシェルへの置換や、自動起動は使いません。

戻す場合:

```sh
herdr-app do layout.switch '{"name":"bottom-tabs"}'
```

レイアウト切替だけでは Squire プロセスを終了しません。終了する場合は Squire 内で `quit` を入力してください。core の停止・再起動は不要です。

`--base-layout` で元レイアウトを指定できます。初回に選んだ元レイアウトと Herdr のホームをデータ側に記録し、異なる設定での再利用は拒否します。テスト用には `--app-home`・`--hc`・`--herdr-app` を指定できます。

## 保存と連携の境界

データは `$XDG_DATA_HOME/squire/squire.sqlite`、未設定時は `~/.local/share/squire/squire.sqlite` に保存します。`--data-dir` で変更できます。ディレクトリは0700、DB は0600です。

保存するのは Work Item、ターミナルとの関連、前回の観測に必要な最小限の情報です。フォルダ・場所ラベル・core ID・ターミナル ID・プログラム名・状態・観測時刻を含みます。生の API 応答、端末タイトル、起動引数、画面、会話本文は DB に保存しません。

観測は `hc connect` の `hello` / `terminal.list` だけを使い、`caller` を付けません。実行エージェントへの送信・割込み・終了や、会話ログの読み取りは実装していません。起動アダプタだけが Squire 自身の `hc run` と Herdr のレイアウト操作を使います。LLM・外部送信機能はありません。ただし、Herdr に追加済みのリモートへは、状態照会のため既存の接続を通してアクセスします。

core API の接続者には同一ユーザーの権限があります。Squire 内の読み取りメソッド制限は、core が強制する認可境界ではありません。

## 構成と検証

- `lib/domain.ml`: Work Item とターミナルの型・関連の解決
- `lib/store.ml`: SQLite、トランザクション、保存済み観測
- `lib/application.ml`: 取得失敗・古い値・明示的な関連付け
- `lib/herdr.ml` / `lib/process.ml`: JSON-RPC と期限付き子プロセス
- `lib/layout.ml` / `lib/launcher.ml`: 個人レイアウトの変換と起動
- `lib/ui.ml` / `bin/main.ml`: 行入力の対話と CLI

自動テストは専用一時ディレクトリと偽の hc / App を使い、本番 core を操作しません。状態報告から仕事を自動完了しないこと、保存失敗、再起動後の保持、古い情報の表示、接続先識別、起動の衝突と復帰を確認します。

Herdr App 0.1.16 / core 0.1.21 を連携対象として調査しています。GUI 上の固定配置・日本語 IME・フォーカス・クリックによる幅変更は、自動テストとは別に実機で確認する項目です。

2026-11-17 に同バージョンの実機で、右端表示、Space / Tab 切替中の固定表示、日本語の貼り付け、フォーカス、幅変更、状態照会、起動の再実行による端末再利用、Squire 終了後の表示復元、Herdr App の終了・再表示後の継続を確認しました。元の `bottom-tabs` に追加された `space-theme` とクリック設定も継承しています。日本語 IME の変換操作そのものは未検証です。
