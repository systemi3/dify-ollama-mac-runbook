# Dify × Ollama ローカル構築 & 運用ランブック（Mac/Apple Silicon）

> **目的**  
> - Mac で **Ollama** を 0.0.0.0:11434 で公開し、Docker 内の **Dify** から **OpenAI 互換**として利用する。  
> - ブラウザは `http://localhost:3000`（nginx ゲートウェイ）で開く。  
> - **プラグインは必須にしない**（必要な人だけ後述のオプション）。

---

## 0. 前提とディレクトリ

- Docker Compose プロジェクトフォルダ：  
  `$COMPOSE_DIR`
- Docker Desktop 起動済み
- Mac の **Homebrew** で `ollama` をインストール済み

便利ワンライナー（API コンテナの Compose ルートがわからないとき）:
```bash
PROJDIR=$(docker inspect docker-api-1 --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
echo "Compose dir: $PROJDIR"
cd "$PROJDIR"
```

---

## 1. Ollama を “公開” 起動（0.0.0.0:11434）

> ※ 手動起動 **または** `brew services` の **どちらか一方** に統一します。

```bash
# 競合回避（停止 & 既存プロセスを終了）
brew services stop ollama || true
pkill -f "ollama serve" || true
sleep 1

# 0.0.0.0 でバックグラウンド起動（ログはホーム配下へ）
OLLAMA_HOST=0.0.0.0:11434 /opt/homebrew/bin/ollama serve > ~/.ollama-serve.log 2>&1 &
sleep 2

# LISTEN 確認（出力に LISTEN があればOK）
lsof -nP -iTCP:11434 -sTCP:LISTEN

# API 応答確認（JSONが返ればOK）
curl -sS http://127.0.0.1:11434/v1/models
curl -sS http://127.0.0.1:11434/api/tags
```

### 1-1. モデルの取得（未取得なら）
```bash
/opt/homebrew/bin/ollama pull llama3.2:3b-instruct-q4_K_M
/opt/homebrew/bin/ollama pull nomic-embed-text
curl -sS http://127.0.0.1:11434/api/tags
```

> **メモ**: Apple Silicon で軽く動かしたい場合は `q4_K_M` 量子化が無難。さらに軽量にするなら `q3_K_L` や 1B/2B 系。

---

## 2. Dify スタック（Docker）を用意

> 既存の `docker-compose.yaml` に **上書きや無効化は不要**。  
> **nginx のゲートウェイ**と**API のポート公開**を override で追加し、**フロント→API** のパスを中継します。

### 2-1. `nginx.conf`（このフォルダに作成）
```nginx
events {}
http {
  server {
    listen 80;

    # フロント（Web）
    location / {
      proxy_pass http://web:3000;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # コンソール API
    location /console/api/ {
      proxy_pass http://api:5001/console/api/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 公開 API（任意）
    location /api/ {
      proxy_pass http://api:5001/api/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
  }
}
```

### 2-2. `docker-compose.override.yml`（このフォルダに作成）
```yaml
services:
  # API をデバッグしやすいようにホスト公開（任意）
  api:
    ports:
      - "5001:5001"

  # フロントと API を束ねるゲートウェイ
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

> **.env の注意**  
> - 最低限 `PLUGINS_ENABLED=true` があればOK。  
> - **`PLUGIN_DAEMON_URL/PORT` を空文字で上書きしない**（ValidationError で API が落ちます）。  
> - プラグインを使わないならその他は未設定のままでOK。

### 2-3. 起動
```bash
cd $COMPOSE_DIR

# コンテナ起動（/ 再作成）
docker compose up -d --force-recreate web api gateway

# API 経路が 200 JSON を返すか確認
curl -i http://localhost:3000/console/api/system-features | head -n 10
```

ブラウザで `http://localhost:3000` を開き、初回セットアップ（管理者アカウント作成）を実施。

---

## 3. Dify に「OpenAI 互換」で Ollama を登録

**画面操作**：`設定 → モデルプロバイダー → 追加 → OpenAI-API-compatible`

- **Model Type**: LLM
- **Model Name**: 任意（例：`llama32-3b`）
- **API Key**: 任意のダミー（Ollama は検証しません）
- **API endpoint URL**: `http://host.docker.internal:11434/v1` ← **`/v1` が必須**
- **model name for API endpoint**: `llama3.2:3b-instruct-q4_K_M`
- 保存

**埋め込みも同様に追加**
- **Model Type**: Text Embedding
- **API endpoint URL**: `http://host.docker.internal:11434/v1`
- **model name for API endpoint**: `nomic-embed-text:latest`

> **保存時 404 が出る場合**: Endpoint の末尾 `/v1` を忘れていないか確認。

---

## 4. システムモデル設定

画面右上の **「システムモデル設定」** を開き、  
- Chat LLM：上で登録した LLM（`llama32-3b` 等）
- Embedding：`nomic-embed-text:latest`  
を選んで保存。

---

## 5. 動作確認コマンド（Docker 内から）

**LLM 応答**
```bash
docker exec -it docker-api-1 bash -lc \
'curl -sS -H "Content-Type: application/json" \
 -d "{\"model\":\"llama3.2:3b-instruct-q4_K_M\",\"messages\":[{\"role\":\"user\",\"content\":\"日本語で1行自己紹介して\"}]}" \
 http://host.docker.internal:11434/v1/chat/completions'
```

**埋め込み**
```bash
docker exec -it docker-api-1 bash -lc \
'curl -sS -H "Content-Type: application/json" \
 -d "{\"model\":\"nomic-embed-text:latest\",\"input\":\"これはテストです\"}" \
 http://host.docker.internal:11434/v1/embeddings | head -c 200 && echo'
```

**HTTP ステータスの簡易確認**
```bash
docker exec -it docker-api-1 bash -lc 'curl -i http://host.docker.internal:11434/v1/models | head -n1'
# => HTTP/1.1 200 OK
```

---

## 6. 再起動ルーチン（毎回これだけでOK）

```bash
# 1) Ollama（Mac 側）
pkill -f "ollama serve" || true
OLLAMA_HOST=0.0.0.0:11434 /opt/homebrew/bin/ollama serve > ~/.ollama-serve.log 2>&1 &
sleep 2

# 2) Dify（Docker 側）
cd $COMPOSE_DIR
docker compose up -d web api gateway

# 3) ヘルス確認
curl -sS http://localhost:3000/console/api/system-features | head -n 1
docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
```

---

## 7. よくあるハマりどころ & 対処

- **保存時「404 page not found」**  
  → Endpoint URL の末尾 `**/v1**` を忘れている。`http://host.docker.internal:11434/v1` に修正。

- **フロント読み込みで JSON でなく HTML が返る（`<!DOCTYPE ...`）**  
  → `web:3000` 直アクセスで `console/api` が 404。**nginx ゲートウェイ**を経由して `http://localhost:3000` を開く。

- **API が再起動ループ & `PLUGIN_DAEMON_URL input is empty`**  
  → `.env` や override で `PLUGIN_DAEMON_URL` を **空文字で上書き**している。  
     その行を **削除** し、未設定（デフォルト）に戻す。

- **コンテナから 127.0.0.1 の Ollama に届かない**  
  → Mac 側が `127.0.0.1` で待受 → **`0.0.0.0:11434` で再起動**。  
     コンテナからは **`host.docker.internal`** でアクセスする。

- **Apple Silicon でクラッシュ/重い**  
  → 量子化を軽めに（`q4_K_M` 〜 `q3_K_L`）。モデルを小さくする（1B/2B）。

---

## 8. （オプション）プラグインを使いたい人向けメモ

- `.env` に最低限：`PLUGINS_ENABLED=true`  
- **やらない方が良い**：`PLUGIN_DAEMON_URL/PORT` を空文字で上書き  
- `plugin_daemon` を使う場合は、公式のサンプル Compose に従うか、既存 `docker-plugin_daemon-1` をそのまま利用してください（本ランブックは **プラグインなしで動かす**前提）。

---

## 9. 参考ワンライナー（トラブル調査）

```bash
# API / Web / ゲートウェイの状態
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | egrep 'docker-(api|web|gateway)-1'

# Web から API 経路が JSON かどうか
curl -i http://localhost:3000/console/api/system-features | head -n 10

# API コンテナ → Ollama 到達チェック（200ならOK）
docker exec -it docker-api-1 bash -lc 'curl -i http://host.docker.internal:11434/v1/models | head -n1'

# エラーログの末尾
docker logs --tail=200 docker-api-1 | tail -n +1
docker logs --tail=200 docker-web-1 | tail -n +1
```

---

### 付録：**よく使うモデル名**
- Chat: `llama3.2:3b-instruct-q4_K_M`
- Embedding: `nomic-embed-text:latest`

**おつかれさまでした！** これを上から実行すれば、非エンジニアでも再現・復旧できます。必要があれば「貼るだけ」スクリプト化も可能です。

