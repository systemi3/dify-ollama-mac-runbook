# トラブルシューティング（Troubleshooting）

実際に遭遇したエラーと対処です。詰まったらまず [切り分けの順番](#切り分けの順番) から。

> 設定値の正本は [`postmortem.md`](postmortem.md) です。本書と食い違う情報を他所で見かけた場合は postmortem を優先してください。

---

## 切り分けの順番

上から順に確認すると、原因の層が特定できます。

1. **Ollama** — ホストで `/v1/models` が 200 か？
2. **Docker → Ollama** — `host.docker.internal:11434` で 200 か？
3. **ゲートウェイ** — `/console/api/system-features` が 200 かつ JSON か？
4. **Dify Web** — 初期セットアップ / ログイン画面が出るか？
5. **Provider 保存** — API Base の末尾が `/v1` か？ `curl` でも 200 か？

---

## 1. 症状別の対処

### 1.1 `Error: listen tcp 127.0.0.1:11434: address already in use`

**原因**: Ollama の多重起動（手動起動と `brew services` の競合）

**対処**: どちらか一方に統一します。

```bash
brew services stop ollama || true
pkill -f "/opt/homebrew/.*/ollama serve" || true
```

---

### 1.2 `curl: (7) Failed to connect to 127.0.0.1:11434`

**原因**: Ollama 未起動、または待受が `127.0.0.1` で Docker から届かない

**対処**: `0.0.0.0` で起動し直します。コンテナからは `host.docker.internal` でアクセスします。

```bash
OLLAMA_HOST=0.0.0.0:11434 /opt/homebrew/bin/ollama serve > ~/.ollama-serve.log 2>&1 &
```

**確認**

```bash
lsof -nP -iTCP:11434 -sTCP:LISTEN
curl -sS http://127.0.0.1:11434/v1/models
docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
```

---

### 1.3 `PLUGIN_DAEMON_URL` を空文字にしてはいけない（誤りの記録）

**症状**

```
pydantic ValidationError: PLUGIN_DAEMON_URL Input should be a valid URL, input is empty
```

API コンテナが再起動を繰り返します。

> ### ⚠️ 過去の誤った対処
>
> 原本のランブック（完全版 10.3）には、次の対処が書かれていました。
>
> > `docker-compose.override.yml` の `api.environment` で **空文字**を入れて無効化、かつ `PLUGIN_DAEMON_HOST=plugin_daemon:5003` を定義。
>
> **これは誤りです。** 空文字で上書きすることが、まさにこのバリデーションエラーの**原因**です。
> `PLUGIN_DAEMON_URL=""` を設定すると Pydantic が「有効な URL ではない」と判定して弾きます。
> 記録として残しますが、**この対処を実行しないでください。**

**正しい原因**

`docker-compose.override.yml` または `.env` で `PLUGIN_DAEMON_URL=""` として**空文字に上書きしている**こと。

**正しい対処**

Plugin Daemon には **2 種類のエンドポイントがあり、両方必要**です。

| 変数 | 値 | プロトコル | 用途 |
|---|---|---|---|
| `PLUGIN_DAEMON_URL` | `http://plugin_daemon:5002` | **HTTP** | HTTP 通信用 |
| `PLUGIN_DAEMON_HOST` | `plugin_daemon:5003` | **gnet/TCP** | 内部プロトコル用 |

**5002 と 5003 は別物です。** 片方だけ設定しても動きません。空文字にするのではなく、正しい値を入れます。

```dotenv
PLUGINS_ENABLED=true
PLUGIN_DAEMON_URL=http://plugin_daemon:5002
PLUGIN_DAEMON_HOST=plugin_daemon:5003
```

公開ポートは必須ではありません。同一 Docker ネットワーク内で名前解決できれば動作します。

**確認**

```bash
docker exec -it docker-api-1 bash -lc 'printenv | egrep -i "PLUGINS_ENABLED|PLUGIN_.*DAEMON"'
docker logs docker-api-1 | egrep -i 'plugin|daemon|error' | tail -n 200
```

---

### 1.4 `GET /console/api/... 404` / `Unexpected token '<', "<!DOCTYPE "...`

**症状**: ブラウザのコンソールに JSON パースエラー。JSON を期待した箇所に HTML が返っている。

**原因**: フロント（`web`）が叩く `/console/api/...` が API に中継されず、静的ファイルまたは 404 HTML に落ちている。

**対処**: Nginx ゲートウェイを導入し、`/console/api/` を `api:5001/console/api/` へ中継します。設定は [`setup.md` の 4章](setup.md#4-nginx-ゲートウェイ設定nginxconf) を参照。

**確認**

```bash
curl -i http://localhost:3000/console/api/system-features | head -n 20
```

`Content-Type: application/json` が返れば OK です。

> `web` を `3000:3000` で直接公開する構成では、この症状が再発します。**公開するのは `gateway` の `3000:80` だけ**にしてください。

---

### 1.5 `Received HTTP/0.9 when not allowed` / `handshake failed, invalid handshake message`

**原因**: `plugin_daemon:5003` は **gnet/TCP の独自プロトコル**であり、HTTP ではありません。`curl` で直接叩くとこのエラーになります。

**対処**: Plugin Daemon に HTTP でアクセスしないこと。Dify が内部プロトコルで利用します。HTTP で疎通を見たい場合は 5002 側です。

---

### 1.6 `file does not exist`（`ollama pull` 時）

**原因**: モデル名 / タグの間違い、または一時的なリポジトリ側の問題

**対処**: 別の量子化・サイズを試すか、少し待って再試行します。

---

### 1.7 `ollama server not responding - could not find ollama app`

**原因**: Ollama デーモンが起動していない

**対処**: `ollama serve` を起動してから `ollama pull` / `ollama run` を実行します。

---

### 1.8 `zsh: parse error near ')'` / `zsh: command not found: services:`

**原因**: YAML や nginx の設定スニペットを**シェルに直接貼り付けた**（ファイルへのリダイレクト保存を忘れた）

**対処**: ヒアドキュメントでファイルに保存してから起動します。

```bash
cat > docker-compose.override.yml <<'YAML'
services:
  gateway:
    image: nginx:alpine
YAML
```

---

### 1.9 モデルプロバイダー保存時の 400 / 404

**原因**: API endpoint URL の末尾 `/v1` 抜け、またはタイプミス

**対処**: `http://host.docker.internal:11434/v1` に修正します。`curl` で 200 が取れる組み合わせに合わせれば確実に保存できます。

---

### 1.10 `docker compose port web 3000` が `:0` を返す

**gateway 方式では正常です。** `web` は直接公開せず、`gateway` の `3000:80` のみを外に出しているためです。

原本の postmortem 1-8 には「`gateway` で `3000:80` を公開する or `web` に直接 `3000:3000` を割り当てる」という2択が記録されていますが、**採用されたのは gateway 方式**です。`web` を直接公開すると 1.4 の症状が再発します。

---

### 1.11 初期設定ページが空白 / エラー

**原因**: ブラウザに古いサイトデータが残っている

**対処**

- Chrome: `chrome://settings/siteData` で `localhost:3000` と `localhost:5001` を個別に削除
- または DevTools → Application → Storage → Clear site data（該当オリジンのみ）

> DevTools Console への貼り付けを求められた場合、`allow pasting` と入力して Enter した後、**必ず貼るスクリプトの内容を確認してから**実行してください。

---

### 1.12 `langgenius/dify-plugin-job-runner:0.2.1` の pull 失敗

**原因**: 非公開 / 存在しないタグ

**対処**: 公開されている `0.2.0-local` を使用します。`job_runner` は不要なら構成から外してください。

---

### 1.13 LM Studio で `GET /v1/v1/models`

**原因**: Base URL の末尾に `/v1` を付けている。Dify 側が `/v1` を付与するため二重になる。

**対処**: Base URL は `http://host.docker.internal:1234`（末尾 `/v1` なし）。

---

### 1.14 Apple Silicon でクラッシュ / 極端に重い

**対処**: 量子化を軽くする（`q4_K_M` → `q3_K_L`）、またはモデルを小さくする（1B / 2B 系）。

LM Studio 側で `Unable to load kernel vs_Equalbool_` などの Metal カーネル読み込み失敗が出る場合は、推論バックエンドの変更・CPU 実行・別モデルを検討してください。

---

## 2. ログの見どころ

```bash
docker logs docker-api-1 | egrep -i 'plugin|daemon|error'
docker logs docker-plugin_daemon-1
```

ブラウザの DevTools → Network で、`/console/api/...` が **200 かつ JSON** で返っているかを確認します。
