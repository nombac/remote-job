# remote-job

長時間かかる計算やビルドを、手元のMacではなく別のMacで実行したいことがあります。しかし、SSH、VPN、専用サーバーは、ネットワーク環境の制限により利用できない場合があります。

`remote-job` は、Dropbox、OneDrive、Google Drive、社内ファイルサーバーなど、既に利用できる同期フォルダをジョブキューとして使うツールです。対象プロジェクトのディレクトリで `job-submit` を実行すると、ワーカー側のMacが同じプロジェクトの `./run` を1回実行します。依頼後は、実行状況とログの確認や処理のキャンセルができます。

## 必要条件と構成

- macOS 13以降
- 両方のMacにローカルマウントされた、同期対象の `WORK_ROOT`
- 実行可能な各プロジェクトが `WORK_ROOT` 以下のディレクトリであり、実行可能な `./run` を含んでいること
- ワーカー側のMacにのみSwiftコンパイラ（必要に応じて `xcode-select --install` を実行）

デフォルトのインストール構成：

```text
~/.local/share/remote-job/          プログラム、設定、ワーカーバイナリ／ログ
~/.local/bin/job-submit             シンボリックリンク
~/.local/bin/job-status             シンボリックリンク
~/.local/bin/job-list               シンボリックリンク
~/.local/bin/job-cancel             シンボリックリンク
~/.local/bin/job-delete             シンボリックリンク
~/.local/bin/job-worker             ワーカー専用シンボリックリンク
~/.local/share/remote-job/worker.lock ローカルのワーカーロック
~/Library/LaunchAgents/
  com.local.remote-job.worker.plist ワーカー側のみ
WORK_ROOT/.remote/{requests,status,cancel} 共有キュー（自動作成）
```

`WORK_ROOT` 自体はこのパッケージでは管理しません。設定ファイルには `WORK_ROOT=/absolute/path` という1行だけが含まれます。

## インストール

このリポジトリを各Macでクローンまたは展開します。論理的には同じ同期ディレクトリを使用しますが、ローカルの絶対パスはMacごとに異なっていても構いません。

クライアント側のMac A：

```sh
./install.sh client --work-root "$HOME/Dropbox/Work"
```

ワーカー側のMac B：

```sh
./install.sh worker --work-root "$HOME/Dropbox/Work"
```

どちらのMacでも、別のインストール先を指定できます：

```sh
./install.sh client --work-root "/path/to/Work" --prefix "$HOME/.local/share/remote-job"
```

`~/.local/bin` が `PATH` に含まれていることを確認してください。インストーラーを再実行すると、同じ構成を維持したままインストール内容が更新されます。

ワーカーの再インストールでは、登録済みLaunchAgentを自動的に再読み込みしません。実行中ジョブを中断せず、新しいワーカーバイナリは次回起動から使われます。plistの変更も適用する場合は、すべてのジョブが終了した後に明示的に再読み込みします：

```sh
./install.sh worker --work-root "$HOME/Dropbox/Work" --reload-launch-agent
```

ワーカーが実行中の場合、`--reload-launch-agent` はエラーで停止します。

### ワーカー側で必要な設定

1. 同期サービスの設定で、ワーカー側Macの `WORK_ROOT` 全体を**常にオフラインで利用可能**、**ダウンロード済み**、または**ローカル**に設定します。プレースホルダーのみのファイルがあると、ジョブが失敗したり、不完全な入力で実行されたりする可能性があります。
2. **システム設定 → プライバシーとセキュリティ → フルディスクアクセス**で、インストーラーに表示された専用バイナリ（通常は以下）を追加して有効にします。

   ```text
   ~/.local/share/remote-job/bin/remote-job-worker
   ```

LaunchAgentはこのバイナリを直接実行するため、`/bin/zsh` に広範なアクセス権を与えることはありません。フルディスクアクセスを変更した後は、ワーカー用インストーラーを再実行するか、一度ログアウトして再ログインしてエージェントを再読み込みしてください。

## 使い方

5つのユーザー向けコマンドは、どちらのMacでも同じです：

```sh
job-submit
job-status
job-list
job-cancel <request-id>
job-delete <request-id>
```

ジョブを投入するには、対象プロジェクトのディレクトリへ移動して、引数なしで `job-submit` を実行します：

```sh
cd "$HOME/Dropbox/Work/simulations/case-01"
job_id=$(job-submit)
job-status "$job_id"
job-list                         # 待機中を含むジョブ一覧（新しい順）
```

`job-submit` は引数を取らず、対象プロジェクトのディレクトリ内で実行する必要があります。`job-cancel <request-id>` と `job-delete <request-id>` は指定したジョブだけを対象とし、`job-status <request-id>` と `job-list` と同様に任意のディレクトリから実行できます。キャンセル対象がすでに終了状態にある場合は、安全に何も行いません。

`job-delete <request-id>` は、状態が `finished`、`error`、`cancelled` のジョブについて、ステータス、ログ、リクエスト、残存キャンセルファイルを削除します。`queued`、`running`、`cancelling`、`stale` は削除できません。削除後は `job-list` と `job-status` から消え、このツールでは元に戻せません。

表示される状態は `queued`、`running`、`cancelling`、`cancelled`、`finished`、`error`、`stale` のいずれかです。`job-status` には必ずリクエストIDを指定します。詳細ステータスでは、利用可能な場合にワーカー側のログパスも表示されます。そのログは `.remote/status/<job-id>.log` に同期されます。

`job-list` は `.remote/status/*.status` と、まだステータスのない待機中リクエストを読み取ります（履歴データベースはありません）。更新時刻を基準に、新しい順で並べます。表示時刻はすべてJSTです。旧バージョンがUTCで記録したステータスもJSTへ変換して表示します：

```text
DIR                          STATE       REQUEST                                               UPDATED (JST)
AAA                          running     20260815T193100JST-...                                 2026-08-15 19:31 JST
BBB                          finished    20260815T181500JST-...                                 2026-08-15 18:15 JST
CCC/DDD                      error       20260815T174200JST-...                                 2026-08-15 17:42 JST
```

### 典型的なリモートワークフロー

長時間実行する場合の典型的な流れは次のとおりです：

```text
Mac B：対象プロジェクトのディレクトリでjob-submit
  ↓
ワーカー側のMacを起動したまま帰宅
  ↓
Mac A：job-list
  ↓
Mac A：job-status <request-id>
  ↓
Mac A：job-cancel <request-id>（必要な場合）
  ↓
完了後：対象プロジェクトのディレクトリで次のジョブをjob-submit
```

Mac Bで長時間ジョブを開始し、その後Mac Aから監視またはキャンセルする場合：

```text
Mac B：対象プロジェクトのディレクトリでjob-submit
  ↓
Mac A：job-status <request-id>
  ↓
Mac A：job-cancel <request-id>（必要な場合）
```

または、Mac Aからリモートで投入し、Mac Bのワーカーに実行させます：

```text
Mac A：対象プロジェクトのディレクトリでjob-submit
  ↓
Mac B：ワーカーが./runを実行
  ↓
Mac A：job-status <request-id> / job-cancel <request-id>
```

ジョブは、次の30秒間隔のアイドルポーリング後にMac Bで開始されます。ステータス、ログ、キャンセルリクエストは、通常の同期フォルダを介してMac間を移動します。

```sh
# Mac A
cd "$HOME/Dropbox/Work/my-project"
id=$(job-submit)
job-status "$id"       # queued → running → finished/error
# job-cancel "$id"     # 必要な場合
```

同梱の [`example-project`](example-project) は、必須となるエントリーポイントの例です。実行可能な `run` は単に `make` を呼び出します。

### ハートビートと `stale`

`./run` の実行中、ワーカーはステータス内の `heartbeat_epoch` を20秒ごとにアトミックに更新します。`job-list` と `job-status` は、`running` または `cancelling` のハートビートが180秒以上前のものである場合、ローカルで `stale` と判定します。同期されたステータスファイル自体は書き換えません。`job-status` では元の値も `reported_state` として表示します。

`stale` は、ステータス上ではジョブが実行中であるものの、最近のワーカーのハートビートが確認できないことを意味します。ジョブの失敗を証明するものでは**ありません**。Mac Bの電源が切れている、ワーカーやOSが停止している、またはフォルダの同期が単に遅れている可能性があります。この表示ルールによって `queued`、`finished`、`error`、`cancelled` が `stale` に変わることはありません。

`stale` では、計算プロセスが監視なしで動いている、すでに終了または停止している、ワーカーMacが停止している、同期が遅延している、ステータスが不正である、といった複数の可能性を区別できません。そのため `job-delete` は `stale` を拒否します。`job-cancel <request-id>` を実行しても、ワーカーがキャンセル要求を処理できなければ状態は `stale` のままです。ワーカーが復帰して状態が `cancelled` になった場合に限り、`job-delete` で削除できます。

### キャンセルの動作

各 `./run` は、それぞれ独立したPOSIXプロセスグループ内で直接開始されます。キャンセル時、ワーカーは状態を `running` から `cancelling` にアトミックに変更し、**プロセスグループ全体**に `SIGTERM` を送信して最大5秒待機します。その後もプロセスが残っていれば、グループに `SIGKILL` を送信します。これにより、親プロセスだけでなく、一般的な `./run → make → Python/Wolfram/その他の計算処理` というプロセスツリー全体が停止します。終了状態は `error` とは区別される `cancelled` です。

待機中ジョブへキャンセルを要求すると、クライアントでは直ちに `cancelling` と表示されます。実行中のワーカーは待機中ジョブのキャンセルも定期的に確認し、現在のジョブの終了を待たずに `cancelled` を記録して対応するリクエストを削除します。各キャンセルファイルの内容とファイル名には、同じグローバルに一意なリクエストIDが使われます。そのため、古いファイルの再出現や同期サービスによる競合コピーが、後続のジョブを対象にすることはありません。終了状態のキャンセルファイルは削除されるだけで、再び処理されることはありません。

## セキュリティモデルと注意事項

- 絶対プロジェクトパスおよび `..` 要素を含むパスは、投入時と実行時の両方で拒否されます。
- ワーカーは実行前にシンボリックリンクを解決し、プロジェクトが解決後の `WORK_ROOT` 内にあることを確認します。
- ワーカーはrootでの実行を拒否し、プロジェクトに固定されたエントリーポイント `./run` だけを実行します。リクエストに含まれるのは任意のコマンドではなくプロジェクトパスであり、`sh -c` は使用しません。
- ワーカーは、ローカルの `~/.local/share/remote-job/worker.lock` に対してノンブロッキングのBSD `flock` を保持します。そのため、launchdから起動されたワーカーと手動で開始した `job-worker` がMac B上で同時に動作することはありません。終了時またはクラッシュ時にはカーネルがロックを解放します。無害なロックファイル自体は残ることがあります。1つのワーカーが同時に処理するジョブは1つだけです。
- `running` と書き込まれたステータスは永続的な実行済み宣言として扱われるため、同じリクエストが二重に実行されることはありません。そのため、ジョブ実行中にワーカーがクラッシュすると、ステータスは `running` のまま残り、最終的に自動再試行ではなく `stale` と表示されます。ログを確認し、必要に応じて新しいジョブを明示的に投入してください。
- ステータスファイルは小さく、アトミックに置き換えられます。リクエストとキャンセルの公開には、各ディレクトリ内でのアトミックな名前変更を使用します。同期サービスは分散トランザクションを保証しないため、同じキューに対して複数のワーカーMacを設定しないでください。
- `./run` はワーカーユーザーの権限で実行され、ワーカーの環境を継承します。これは任意の信頼済みコードです。`.remote/requests` と `WORK_ROOT` 以下のプロジェクトファイルの両方に書き込める人は、そのコードを実行させることができます。信頼できない共有フォルダでは使用しないでください。
- キャンセルは、そのファイルがワーカー側Macに到達して初めて検出されます。新しいセッションを作成するなどして、意図的にジョブのプロセスグループから離脱するプログラムは、グループ単位のキャンセル対象外です。
- このキューには、認証、暗号化、汎用的なジョブタイムアウト、リソース制限、自動的な履歴削除の機能はありません。同期サービスが削除済みデータやバージョン履歴を保持する場合があります。
- フルディスクアクセスは強力な権限です。インストールされたワーカーバイナリだけに付与し、使用前にソースコードとビルド元を確認してください。

## アンインストール

キューの履歴を残したまま、インストール済みプログラム、コマンドリンク、LaunchAgentを削除します：

```sh
./uninstall.sh
```

`WORK_ROOT/.remote` も完全に削除する場合：

```sh
./uninstall.sh --purge
```

インストール先を変更している場合は、同じ `--prefix` を指定してください。設定ファイルがすでに存在しない状態で `--purge` を使用する場合は、`--work-root` も指定します。

## 開発

インストールせずにワーカーをビルドします：

```sh
swift build -c release
```

ワーカー側のMacで手動実行します（通常はlaunchdが実行します）：

```sh
job-worker
```

ビルド後に回帰テスト一式を実行します：

```sh
tests/list-stale.sh
tests/heartbeat.sh
tests/integration.sh
tests/worker-lock.sh
tests/install-client.sh
tests/install-worker.sh
```

ワーカーはキューを1回スキャンし、通常は1件のジョブを処理した後に終了します。そのジョブの実行中は、ID固有のキャンセルファイルを監視するために動作し続けます。`launchd` が30秒間隔のアイドルポーリングを提供し、同じLaunchAgentのインスタンスが重複して動作するのを防ぎます。
