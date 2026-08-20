# Dify × Ollama ローカル環境 **完全ランブック**
（Mac/Apple Silicon・Docker・ゲートウェイ付き / 実績ベースの手順＋失敗事例）

最終更新: 2025-08-18

---

## 0. ゴール
- Dify の Web コンソールを `http://localhost:3000` で開き、
- モデルプロバイダー **OpenAI API Compatible** 経由で **Ollama** を接続、
- チャット/ワークフローのプレビューまで到達する。

---

## 1. 構成（最終形）

```
[ブラウザ] -- http://localhost:3000
        │
      [gateway(Nginx)]  ← 3000:80
        ├── /          → web:3000  (静的フロント)
        ├── /console/api/ → api:5001 (Dify API: Console API)
        └── /api/      → api:5001 (Public API/任意)
[Docker]
  ├─ web (langgenius/dify-web:1.7.2)
  ├─ api (langgenius/dify-api:1.7.2)
  ├─ db (postgres)
  ├─ redis
  ├─ sandbox (langgenius/dify-sandbox:0.2.12)
  └─ plugin_daemon (langgenius/dify-plugin-daemon:0.2.0-local) ※起動のみ・今回は未使用
[ホスト]
  └─ Ollama サーバ（0.11.4）: 0.0.0.0:11434
```

> ポイント：Dify のフロントと API の相対パスが揃うよう、**Nginx ゲートウェイ**で中継します。  
> 直接 `web` をポート公開して開くと、`/console/api/...` が 404 になるケースがあるため。

---

## 2. 前提（Mac）
- macOS + Apple Silicon (M4/M3/M2 etc.)
- Homebrew / Docker Desktop インストール済み
- シェルは zsh（デフォルト）

---

## 3. Ollama をホストで常駐（0.0.0.0 で待受）

> 既に Homebrew サービスで走っている場合は **停止→手動常駐**のどちらか一方に統一。

```bash
# 競合停止（走ってなくてもOK）
brew services stop ollama || true
pkill -f "/opt/homebrew/.*/ollama serve" || true
sleep 1

# 重要：0.0.0.0 で待受（Docker から見えるようにする）
# ※ 再起動後は手動起動が必要。自動化したい場合は別途 launchd を設定。
OLLAMA_HOST=0.0.0.0:11434 /opt/homebrew/bin/ollama serve > ~/.ollama-serve.log 2>&1 &
disown
sleep 2

# 待受確認
lsof -nP -iTCP:11434 -sTCP:LISTEN
curl -sS http://127.0.0.1:11434/api/tags
curl -sS http://127.0.0.1:11434/v1/models
```

### 3.1 モデルの取得（軽量量子化）
```bash
/opt/homebrew/bin/ollama pull llama3.2:3b-instruct-q4_K_M
/opt/homebrew/bin/ollama pull nomic-embed-text
```

### 3.2 動作確認（ホスト側）
```bash
# Chat
curl -sS -H "Content-Type: application/json" \
  -d '{"model":"llama3.2:3b-instruct-q4_K_M","messages":[{"role":"user","content":"日本語で1行自己紹介して"}]}' \
  http://127.0.0.1:11434/v1/chat/completions | sed -E 's/{"id".*/.../'
# Embedding
curl -sS -H "Content-Type: application/json" \
  -d '{"model":"nomic-embed-text:latest","input":"これはテストです"}' \
  http://127.0.0.1:11434/v1/embeddings | head -c 200 && echo
```

> **OK 条件**：`/v1/models` が 200 で、`llama3.2:3b-instruct-q4_K_M` と `nomic-embed-text:latest` が見える。

---

## 4. Dify（Docker Compose）を起動

> すでにプロジェクトがある前提：  
> `/Users/＜あなた＞/docker-lessons/dify-min/dify/docker` が compose ディレクトリ。

### 4.1 .env の整備
```bash
cd /Users/＜あなた＞/docker-lessons/dify-min/dify/docker

cp .env ".env.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
[ -f .env ] || touch .env

# 旧キーは削除（URL/PORT 系は今回未使用にする）
sed -i '' '/^PLUGIN_DAEMON_URL=/d;/^PLUGIN_DAEMON_PORT=/d;/^EXPOSE_PLUGIN_DAEMON_PORT=/d' .env

# 有効化フラグと接続先（5003/TCP）
grep -q '^PLUGINS_ENABLED=' .env    || echo 'PLUGINS_ENABLED=true' >> .env
grep -q '^PLUGIN_DAEMON_HOST=' .env || echo 'PLUGIN_DAEMON_HOST=plugin_daemon:5003' >> .env
grep -q '^PLUGIN_DAEMON_KEY=' .env  || echo "PLUGIN_DAEMON_KEY=$(openssl rand -base64 32)" >> .env
```

> **注意**：Dify 1.7.2 では `PLUGIN_DAEMON_URL` が未設定だと起動時 ValidationError になる実装がありました。  
> 今回は **Nginx ゲートウェイ＋OpenAI Compatible** で進めるため、プラグインは起動のみ（利用はしない）ですが、
> 互換性のため `PLUGINS_ENABLED=true` と `PLUGIN_DAEMON_HOST` は入れておきます。

### 4.2 Nginx ゲートウェイ設定（`nginx.conf`）
> コンソールAPI を `/console/api/` に固定中継することでフロントの 404/JSON 取違いを回避します。

`nginx.conf`（compose ディレクトリ直下）
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

### 4.3 docker-compose.override.yml にゲートウェイ追加
```yaml
# docker-compose.override.yml
services:
  api:
    environment:
      PLUGINS_ENABLED: "true"
      PLUGIN_DAEMON_HOST: "plugin_daemon:5003"
      PLUGIN_DAEMON_KEY: "${PLUGIN_DAEMON_KEY}"
      # 旧キーは空で上書きして無効化（Validation を避けるため、必要に応じて残す）
      PLUGIN_DAEMON_URL: ""
      PLUGIN_DAEMON_PORT: ""
      EXPOSE_PLUGIN_DAEMON_PORT: ""

  plugin_daemon:
    image: langgenius/dify-plugin-daemon:0.2.0-local
    env_file:
      - ./.env
    ports:
      - "5003:5003"
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

### 4.4 コンテナ起動
```bash
docker compose up -d --force-recreate plugin_daemon api web gateway
```

### 4.5 API 中継のヘルスチェック
```bash
# JSON が返ること（application/json）
curl -i http://localhost:3000/console/api/system-features | head -n 20
```

---

## 5. ブラウザ側の注意（キャッシュ/サイトデータ）

**初回設定ページが空白/エラー**のときは：
- Chrome のアドレスバーで `chrome://settings/siteData` を開く  
  `localhost:3000` と `localhost:5001` があれば **個別に「データを削除」**
- もしくは DevTools → Application → Storage → Clear site data（該当オリジンのみ）

> DevTools Console に貼り付け実行を求められる場合、**`allow pasting`** と入力して Enter、
> その後に必ず **貼るスクリプトの内容を確認**してから実行。

---

## 6. Dify 管理者セットアップ → ログイン
- `http://localhost:3000` を開く
- 初期ウィザード（管理者メール/パスワード設定）
- ログイン

> 404 や `<!DOCTYPE ... is not valid JSON` などは **ゲートウェイ未設定/ルーティング不整合**が原因の典型。  
> 本書の Nginx 設定を必ず入れてから再読み込み。

---

## 7. モデルプロバイダー（OpenAI 互換 → Ollama 接続）

### 7.1 事前にコンテナから Ollama が見えるか確認
```bash
# api コンテナ内から
docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
# → llama3.2:3b-instruct-q4_K_M などが見えればOK
```

### 7.2 Dify での入力例
- Provider: **OpenAI API Compatible**（OpenAI 互換）
- API Base: `http://host.docker.internal:11434/v1`
- API Key: （ダミー文字列でOK。例：`test`）
- Model name:  
  - LLM: `llama3.2:3b-instruct-q4_K_M`
  - Embedding: `nomic-embed-text:latest`

> **保存時の 400**：多くは API Base のパス/末尾 `/v1` 抜け・タイプミスです。  
> `curl` で 200 が取れる組合せに合わせれば確実に保存できます。

---

## 8. アプリ/ワークフローのプレビュー
- アプリ（Chat）または ワークフロー作成
- モデルに `llama3.2:3b-instruct-q4_K_M` を選択
- プレビューで入出力を確認（簡単な挨拶など）

---

## 9.（参考）LLM Studio を併用した場合の注意
- `GET /v1/v1/models` のように **重複 `/v1`** を要求されることがある → サーバ側が 200 を返しても、クライアント側が 400 を出す。
- Apple Silicon/Metal で `Unable to load kernel vs_Equalbool_` などの **Metal カーネル読み込み失敗**が発生する場合あり。  
  LLM Studio 側の推論バックエンド変更や CPU 実行、あるいは別モデルを推奨。

---

## 10. 失敗事例と対処（抜粋）

### 10.1 `Error: listen tcp 127.0.0.1:11434: address already in use`
- **原因**：Ollama の多重起動（手動と brew サービスの競合）
- **対処**：
  ```bash
  brew services stop ollama || true
  pkill -f "/opt/homebrew/.*/ollama serve" || true
  ```

### 10.2 `curl: (7) Failed to connect to 127.0.0.1:11434`
- **原因**：Ollama 未起動 / 待受が `127.0.0.1` で Docker から届かない
- **対処**：`OLLAMA_HOST=0.0.0.0:11434` で起動し直し。  
  コンテナからは `host.docker.internal` 経由でアクセス。

### 10.3 `pydantic ValidationError: PLUGIN_DAEMON_URL Input should be a valid URL, input is empty`
- **原因**：Dify 1.7.2 の設定バリデーションで `PLUGIN_DAEMON_URL` 未設定が NG になることがある
- **対処**：`docker-compose.override.yml` の `api.environment` で **空文字**を入れて無効化、
  かつ `PLUGIN_DAEMON_HOST=plugin_daemon:5003` を定義。

### 10.4 `GET /console/api/... 404` / `Unexpected token '<', "<!DOCTYPE "...`（JSON でなく HTML が来る）
- **原因**：フロントが `/console/api/` を叩いた先が `web`（静的）に落ちている
- **対処**：本書の **Nginx ゲートウェイ**設定を導入。`/console/api/` → `api:5001/console/api/` を必ず中継。

### 10.5 `Received HTTP/0.9 when not allowed` / `handshake failed, invalid handshake message`
- **原因**：`plugin_daemon:5003` は gnet/TCP での独自プロトコル。HTTP で直接叩くとこのエラー。
- **対処**：プラグインダエモンに HTTP でアクセスしない。Dify が内部プロトコルで利用。

### 10.6 `file does not exist`（ollama pull）
- **原因**：モデル名/タグ間違い、または一時的なリポジトリ側問題
- **対処**：別の量子化/サイズを試す、少し待って再試行。

### 10.7 `ollama server not responding - could not find ollama app`
- **原因**：Ollama デーモン未起動
- **対処**：`ollama serve` を起動してから `ollama pull` / `ollama run`。

### 10.8 `zsh: parse error near ')'` / `zsh: command not found: services:`
- **原因**：YAML/設定スニペットを **シェルに直接貼った**（リダイレクト保存を忘れた）
- **対処**：`cat > ファイル名 <<'YAML' ... YAML` で **ファイルに保存してから** `docker compose up`。

---

## 11. 日常のヘルスチェック（4 コマンド）
```bash
# 1) Ollama 起動確認
lsof -nP -iTCP:11434 -sTCP:LISTEN && curl -sS http://127.0.0.1:11434/v1/models

# 2) コンテナ一覧
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# 3) ゲートウェイ→API の JSON 確認
curl -i http://localhost:3000/console/api/system-features | head -n 20

# 4) コンテナ内から Ollama 可視性確認
docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
```

---

## 12. トラブル切り分けの順番（詰まったらこれ）
1) **Ollama**：`/v1/models` がホストで 200 か？  
2) **Docker から Ollama**：`host.docker.internal:11434` で 200 か？  
3) **ゲートウェイ**：`/console/api/system-features` が 200(JSON) か？  
4) **Dify Web**：初期セットアップ画面/ログイン画面が出るか？  
5) **Provider 保存**：`API Base=/v1` 末尾まで含むか？curl でも 200 か？

---

## 13. 便利ワンライナー集

### 13.1 Compose プロジェクトディレクトリを逆引き
```bash
PROJDIR=$(docker inspect docker-api-1 --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
echo "Compose dir: $PROJDIR"
cd "$PROJDIR"
```

### 13.2 API / Web / ゲートウェイの再作成
```bash
docker compose up -d --force-recreate api web gateway
```

### 13.3 Web の公開ポートを確認
```bash
docker compose port web 3000   # 例: 0.0.0.0:3000 が出ればOK
```

---

## 14. 付録：学習ロードマップ（超要約）
- **Docker**：`docker compose` の基本、サービス間ネットワーク、`host.docker.internal`
- **HTTP/プロキシ**：Nginx での `location` / `proxy_pass` とヘッダ
- **LLM ランタイム**：Ollama の API `/v1/models`、モデル名と量子化
- **Dify 設計**：Web と Console API の分離、Provider と Model の概念
- **macOS/Metal**：Apple Silicon の GPU メモリ、Metal 実行時の既知エラー回避

---

## 15. 参考：完全クリーンアップ（必要なときだけ）
```bash
# Ollama
brew services stop ollama || true
pkill -f "/opt/homebrew/.*/ollama serve" || true

# Dify（compose ディレクトリで）
docker compose down -v     # ボリューム含め全削除（DB初期化）注意！

# ブラウザ
# localhost:3000 / 5001 のサイトデータを個別削除
```

---

### おわりに
このランブックは、実際に遭遇したエラーと解決策をすべて取り込み、**順番どおりに辿るだけ**で再現できるように作っています。  
もし新しい症状に遭遇したら、該当コマンドの出力とあわせて追記できる構成にしてあります。

Happy debugging! 🚀
