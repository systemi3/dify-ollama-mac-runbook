# 構築手順（Setup）

Mac / Apple Silicon で **Ollama** をホスト常駐させ、Docker 上の **Dify** から OpenAI 互換として利用するまでの手順です。

> **設定値の正本について**
> 本書の設定値は [`postmortem.md`](postmortem.md)（解決後の記録）に準拠しています。
> 原本のランブック2本と食い違う箇所は、すべて postmortem 側を採用しました。

---

## 0. 前提

| 項目 | 条件 |
|---|---|
| OS | macOS + Apple Silicon（M2 以降） |
| 必須 | Homebrew / Docker Desktop |
| シェル | zsh |
| Dify | 1.7.2 系 |
| Ollama | 0.11.4 系 |

Docker Compose のプロジェクトディレクトリを `$COMPOSE_DIR` と表記します。場所が分からない場合は次で逆引きできます。

```bash
COMPOSE_DIR=$(docker inspect docker-api-1 --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
echo "Compose dir: $COMPOSE_DIR"
cd "$COMPOSE_DIR"
```

---

## 1. 構成（最終形）

```
[ブラウザ] -- http://localhost:3000
        │
      [gateway(Nginx)]  ← 3000:80
        ├── /                → web:3000   (静的フロント)
        ├── /console/api/    → api:5001   (Dify Console API)
        └── /api/            → api:5001   (Public API/任意)
[Docker]
  ├─ web           (langgenius/dify-web:1.7.2)
  ├─ api           (langgenius/dify-api:1.7.2)
  ├─ db            (postgres)
  ├─ redis
  ├─ sandbox       (langgenius/dify-sandbox:0.2.12)
  └─ plugin_daemon (langgenius/dify-plugin-daemon:0.2.0-local)
[ホスト]
  └─ Ollama サーバ: 0.0.0.0:11434
```

**ポート公開は `gateway` の `3000:80` のみ**です。`web` は直接公開しません。

`web` を `3000:3000` で直接公開すると `/console/api/...` が `web`（Next.js）に届いて 404 HTML を返し、ブラウザに `Unexpected token '<', "<!DOCTYPE "...` が出ます。この経路不整合を解消するための gateway です。

---

## 2. Ollama をホストで常駐（0.0.0.0 で待受）

`brew services` と手動起動は **どちらか一方**に統一します。

```bash
# 競合停止（走っていなくても OK）
brew services stop ollama || true
pkill -f "/opt/homebrew/.*/ollama serve" || true
sleep 1

# 0.0.0.0 で待受（Docker から見えるようにする）
OLLAMA_HOST=0.0.0.0:11434 /opt/homebrew/bin/ollama serve > ~/.ollama-serve.log 2>&1 &
disown
sleep 2

# 待受確認
lsof -nP -iTCP:11434 -sTCP:LISTEN
curl -sS http://127.0.0.1:11434/v1/models
```

> `127.0.0.1` で待受するとコンテナから届きません。必ず `0.0.0.0` です。
> 再起動後は手動起動が必要です。自動化する場合は launchd を別途設定してください。

### 2.1 モデルの取得

```bash
/opt/homebrew/bin/ollama pull llama3.2:3b-instruct-q4_K_M
/opt/homebrew/bin/ollama pull nomic-embed-text
curl -sS http://127.0.0.1:11434/api/tags
```

**OK 条件**: `/v1/models` が 200 で、`llama3.2:3b-instruct-q4_K_M` と `nomic-embed-text:latest` が見えること。

---

## 3. `.env` の設定 ★重要

Plugin Daemon には **2 種類のエンドポイント**があり、**両方必要**です。

| 変数 | 値 | プロトコル |
|---|---|---|
| `PLUGIN_DAEMON_URL` | `http://plugin_daemon:5002` | **HTTP** |
| `PLUGIN_DAEMON_HOST` | `plugin_daemon:5003` | **gnet/TCP** |

5002 と 5003 は別物です。片方だけでは動きません。

```bash
cd "$COMPOSE_DIR"
cp .env ".env.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
[ -f .env ] || touch .env

cat >> .env <<'ENV'
PLUGINS_ENABLED=true
PLUGIN_DAEMON_URL=http://plugin_daemon:5002
PLUGIN_DAEMON_HOST=plugin_daemon:5003
ENV
```

> **`PLUGIN_DAEMON_URL` を空文字で上書きしないでください。**
> Pydantic のバリデーションに弾かれ、API が再起動ループに入ります。
> 詳細は [`troubleshooting.md` の該当項目](troubleshooting.md#plugin_daemon_url-を空文字にしてはいけない誤りの記録) を参照。

公開ポートは必須ではありません。同一 Docker ネットワーク内で名前解決できれば動作します。

---

## 4. Nginx ゲートウェイ設定（`nginx.conf`）

`$COMPOSE_DIR` 直下に作成します。

```nginx
worker_processes  1;
events { worker_connections  1024; }
http {
  sendfile on;
  server {
    listen 80;

    # 1) フロント
    location / {
      proxy_pass http://web:3000/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 2) Console API
    location /console/api/ {
      proxy_pass http://api:5001/console/api/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 3) Public API（任意）
    location /api/ {
      proxy_pass http://api:5001/api/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
  }
}
```

> **`proxy_pass` の末尾スラッシュは必須です（URI 置換が効かなくなるため）。**
> nginx は `proxy_pass` に URI 部分（末尾 `/` を含む）があるとき、`location` にマッチした部分を置換して転送します。末尾スラッシュを省くと置換が行われず、元のパスがそのまま連結されて意図しない経路になります。上記3つはすべて末尾スラッシュ付きで動作実績があります。

---

## 5. `docker-compose.override.yml`

`$COMPOSE_DIR` 直下に作成します。

```yaml
services:
  api:
    environment:
      PLUGINS_ENABLED: "true"
      PLUGIN_DAEMON_URL: "http://plugin_daemon:5002"
      PLUGIN_DAEMON_HOST: "plugin_daemon:5003"

  plugin_daemon:
    image: langgenius/dify-plugin-daemon:0.2.0-local
    env_file:
      - ./.env
    restart: unless-stopped

  gateway:
    image: nginx:alpine
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    ports:
      - "3000:80"
    depends_on:
      - web
      - api
```

> `plugin-job-runner` は不要なら構成から外してください。`0.2.1` タグは非公開のため pull に失敗します。使う場合は `0.2.0-local` を指定します。

---

## 6. 起動

```bash
cd "$COMPOSE_DIR"
docker compose up -d --force-recreate gateway api web plugin_daemon
```

### ヘルスチェック

```bash
# JSON（application/json）が返ること
curl -i http://localhost:3000/console/api/system-features | head -n 20
```

HTML が返る場合は gateway の設定が効いていません。[`troubleshooting.md`](troubleshooting.md) を参照してください。

---

## 7. 管理者セットアップ

1. `http://localhost:3000` を開く
2. 初期ウィザードで管理者メール / パスワードを設定
3. ログイン

画面が空白またはエラーになる場合は、ブラウザのサイトデータを削除します。

- Chrome: `chrome://settings/siteData` で `localhost:3000` と `localhost:5001` を個別に削除
- または DevTools → Application → Storage → Clear site data（該当オリジンのみ）

---

## 8. Ollama をモデルプロバイダーとして登録

### 8.1 事前確認

```bash
docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
```

`llama3.2:3b-instruct-q4_K_M` などが見えれば OK です。

### 8.2 Dify での入力

`設定 → モデルプロバイダー → 追加 → OpenAI-API-compatible`

**LLM**

| 項目 | 値 |
|---|---|
| Model Type | LLM |
| Model Name | 任意（例: `llama32-3b`） |
| API Key | 任意のダミー（例: `test`）。Ollama は検証しません |
| API endpoint URL | `http://host.docker.internal:11434/v1` |
| model name for API endpoint | `llama3.2:3b-instruct-q4_K_M` |

**Embedding**

| 項目 | 値 |
|---|---|
| Model Type | Text Embedding |
| API endpoint URL | `http://host.docker.internal:11434/v1` |
| model name for API endpoint | `nomic-embed-text:latest` |

> **末尾の `/v1` は必須です。** 保存時の 400 / 404 はほぼこれが原因です。

### 8.3 システムモデル設定

画面右上の「システムモデル設定」で、Chat LLM と Embedding に上で登録したモデルを選んで保存します。

---

## 9. 動作確認

アプリ（Chat）またはワークフローを作成し、モデルに `llama3.2:3b-instruct-q4_K_M` を選択してプレビューで応答を確認します。

日常の起動・確認手順は [`operations.md`](operations.md) を参照してください。

---

## 付録: LM Studio を併用する場合

- Base URL は `http://host.docker.internal:1234`（**末尾 `/v1` を付けない**。Dify 側が付与します）
- 重ねると `GET /v1/v1/models` となり、サーバが 200 を返してもクライアントが 400 を出します
- Apple Silicon で `Unable to load kernel vs_Equalbool_` などの Metal カーネル読み込み失敗が起きる場合は、推論バックエンドの変更・CPU 実行・別モデルを検討してください
