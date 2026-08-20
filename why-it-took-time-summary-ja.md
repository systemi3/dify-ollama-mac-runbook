# なぜ時間がかかったのか — トラブル項目別まとめ（ポストモーテム）

対象期間：2025-08-12 〜 2025-08-18  
対象環境：macOS（Apple Silicon: M4）/ Docker Desktop / Dify 1.7.2 / plugin_daemon 0.2.0-local / Ollama 0.11.4 / LLM Studio (OpenAI 互換 API)

---

## 0. 結論（要点）

- **原因は単一ではなく複合要因**。Ollama の公開先（`127.0.0.1` vs `0.0.0.0`）、Dify の **Plugin Daemon 変数の取り扱い**、Web/API の **リバースプロキシ不整合**、**LLM Studio の OpenAI 互換 URL 末尾 `/v1` 二重化**、そして **ブラウザキャッシュ** が絡み合っていました。  
- **決定打**は以下：  
  1) **Ollama を `0.0.0.0:11434` で待受**に変更（コンテナから到達可）  
  2) **API への逆プロキシ（Nginx ゲートウェイ）**を導入し `/console/api → api:5001` を正しく中継  
  3) **OpenAI 互換の Base URL を `/v1` なし**で設定（`http://<host>:<port>`）  
  4) **Plugin Daemon の環境変数**は `PLUGIN_DAEMON_HOST`（gnet:5003）と **`PLUGIN_DAEMON_URL` は空にしない**（バリデーションを満たす）

---

## 1. 項目別の症状・原因・対策

### 1-1. Ollama がコンテナから見えなかった（127.0.0.1 問題）
- **症状**
  - ホストで `curl 127.0.0.1:11434` は成功するが、**コンテナ内からは失敗**。  
  - エラー例：`curl: (7) Failed to connect to host.docker.internal port 11434`
- **直接原因**
  - Ollama を `127.0.0.1:11434` で起動していたため**外部（= コンテナ）から到達不可**。
- **根本原因**
  - 「ローカルで OK でも、Docker からは別ネットワーク」という前提抜け。
- **対策**
  - **Ollama を公開**して起動：  
    ```bash
    # 既存を停止
    brew services stop ollama || true
    pkill -f "/opt/homebrew/.*/ollama serve" || true
    
    # 0.0.0.0 で再起動（バックグラウンド）
    OLLAMA_HOST=0.0.0.0:11434 /opt/homebrew/bin/ollama serve > ~/.ollama-serve.log 2>&1 &
    disown
    ```
  - **確認**
    ```bash
    lsof -nP -iTCP:11434 -sTCP:LISTEN
    curl -sS http://127.0.0.1:11434/v1/models
    docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
    ```

---

### 1-2. Plugin Daemon（プラグイン）設定の混乱とバリデーション落ち
- **症状**
  - Dify API が再起動を繰り返す。ログに：  
    `ValidationError: PLUGIN_DAEMON_URL Input should be a valid URL, input is empty`
- **直接原因**
  - `docker-compose.override.yml` で `PLUGIN_DAEMON_URL=""` として**空文字に上書き** → **Pydantic に弾かれる**。
- **背景（混乱の源）**
  - Plugin Daemon には **2 種のエンドポイント**が存在：  
    - **HTTP 用（デフォルト 5002）** → `PLUGIN_DAEMON_URL=http://plugin_daemon:5002`  
    - **gnet/TCP 用（5003）** → `PLUGIN_DAEMON_HOST=plugin_daemon:5003`  
  - 5003 は **HTTP ではない**ため `curl` で叩くと **HTTP/0.9 エラー**や**ハンドシェイク失敗**になる。
- **正解パターン（Dify 1.7.2 の挙動上おすすめ）**
  - `.env` 例：
    ```dotenv
    PLUGINS_ENABLED=true
    PLUGIN_DAEMON_URL=http://plugin_daemon:5002
    PLUGIN_DAEMON_HOST=plugin_daemon:5003
    # 公開ポートは必須ではない（同一ネット内で名前解決できればOK）
    ```
  - **確認**
    ```bash
    docker exec -it docker-api-1 bash -lc 'printenv | egrep -i "PLUGINS_ENABLED|PLUGIN_.*DAEMON"'
    docker logs docker-api-1 | egrep -i 'plugin|daemon|error' | tail -n 200
    ```

---

### 1-3. Web と API の経路不整合（Unexpected token '<'）
- **症状**
  - ブラウザのコンソールに  
    `Unexpected token '<', "<!DOCTYPE "... is not valid JSON`  
    `console/api/system-features: 404`
- **直接原因**
  - フロント（`web`）が叩く `/console/api/...` を **API に中継できていない**（静的ファイルや 404 HTML が返る）。
- **対策（Nginx ゲートウェイ導入）**
  - `gateway` を追加、以下のように中継：
    ```nginx
    # /console は web へ
    location /console/ {
      proxy_pass http://web:3000/;
    }
    # /console/api は api へ
    location /console/api/ {
      proxy_pass http://api:5001/console/api/;
    }
    # （任意）公開 API も中継
    location /api/ {
      proxy_pass http://api:5001/api/;
    }
    ```
  - **確認**
    ```bash
    curl -i http://localhost:3000/console/api/system-features | head -n 20
    ```

---

### 1-4. LLM Studio の OpenAI 互換 URL に `/v1` を重ね書き
- **症状**
  - LLM Studio ログ：  
    `Unexpected endpoint or method. (GET /v1/v1/models)`
- **原因**
  - Dify 側が自動で `/v1` を付ける前提なのに、**Base URL にも `/v1` を含めて**しまい **二重化**。
- **対策**
  - **Base URL は末尾 `/v1` を付けない**：  
    `http://<ホストまたは host.docker.internal>:1234`
  - **確認**
    ```bash
    docker exec -it docker-api-1 bash -lc \
      'curl -sS -H "Authorization: Bearer dummy" http://host.docker.internal:1234/v1/models'
    ```

---

### 1-5. Apple Silicon（Metal）固有のカーネルエラー
- **症状**
  - LLM Studio 推論時：`Unable to load kernel vs_Equalbool_` など **Metal カーネル読み込み失敗**。
- **原因**
  - 特定モデル／ビルドで **Metal/MPS カーネル不整合**。
- **対策**
  - **Ollama の安定ビルド**（例：`llama3.2:3b-instruct-q4_K_M`）を優先。  
  - LLM Studio を使う場合は **別モデル**や **最新版**で再検証。必要なら **CPU fallback**／**Metal 無効**設定を検討。

---

### 1-6. 「#」行をそのまま貼り付け → `zsh: command not found: #`
- **症状**
  - コメント行まで貼り付け、`zsh: command not found: #` が多発。
- **対策**
  - **コメントを除いて実行**、もしくは **ブロックを 1 行ずつ貼る**。  
  - `cat <<'SH'` の **ヒアドキュメント**で “まとめ貼り” → “ファイル化”→ “後で実行”も安全。

---

### 1-7. 非公開イメージに `pull access denied`
- **症状**
  - `langgenius/dify-plugin-job-runner:0.2.1` の **pull 失敗**。
- **原因**
  - イメージが **非公開／存在しないタグ**。
- **対策**
  - 公開されている `0.2.0-local` を使用。`job_runner` は不要なら構成から外す。

---

### 1-8. Web コンテナのポート未公開
- **症状**
  - `docker compose port web 3000` が `:0` を返す（未公開）。
- **対策**
  - Nginx `gateway` で `3000:80` を公開する or `web` に直接 `3000:3000` を割り当てる。

---

## 2. 再発防止のためのチェックリスト

1. **Ollama**  
   ```bash
   lsof -nP -iTCP:11434 -sTCP:LISTEN
   curl -sS http://127.0.0.1:11434/v1/models
   docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
   ```
2. **Plugin Daemon 変数**  
   ```bash
   docker exec -it docker-api-1 bash -lc 'printenv | egrep -i "PLUGINS_ENABLED|PLUGIN_.*DAEMON"'
   # PLUGINS_ENABLED=true
   # PLUGIN_DAEMON_URL=http://plugin_daemon:5002
   # PLUGIN_DAEMON_HOST=plugin_daemon:5003
   ```
3. **API 逆プロキシ**  
   ```bash
   curl -i http://localhost:3000/console/api/system-features | head -n 20
   ```
4. **LLM Studio Base URL**  
   - 末尾 `/v1` は **付けない**（Dify が付ける）。
5. **ブラウザ**  
   - ハードリロード / サイトデータの削除（対象：`http://localhost:3000`）。
6. **エラーログの見所**  
   - `docker logs docker-api-1 | egrep -i 'plugin|daemon|error'`  
   - `docker logs docker-plugin_daemon-1`  
   - ブラウザ DevTools Network（`/console/api/...` が 200 & JSON か）

---

## 3. 復旧の最短手順（TL;DR）

```bash
# 1) Ollama を 0.0.0.0 で起動
brew services stop ollama || true
pkill -f "/opt/homebrew/.*/ollama serve" || true
OLLAMA_HOST=0.0.0.0:11434 /opt/homebrew/bin/ollama serve > ~/.ollama-serve.log 2>&1 &
disown

# 2) Dify 環境変数（.env）
cat > .env <<'ENV'
PLUGINS_ENABLED=true
PLUGIN_DAEMON_URL=http://plugin_daemon:5002
PLUGIN_DAEMON_HOST=plugin_daemon:5003
ENV

# 3) Nginx ゲートウェイ（docker-compose.override.yml / nginx.conf は既存を利用）
docker compose up -d --force-recreate gateway api web

# 4) 動作確認
curl -sS http://localhost:3000/console/api/system-features | jq .  # (* jq が無ければ省略)
docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
```

> **LLM Studio を使う場合**：Base URL は `http://host.docker.internal:1234`（末尾 `/v1` なし）。

---

## 4. 参考：実際に効いた検証コマンド

```bash
# Plugin Daemon 5003 は HTTP ではない（ハンドシェイク失敗が正常）
docker exec -it docker-api-1 bash -lc 'curl -sS http://plugin_daemon:5003/health/check || true'

# 代わりに TCP 到達確認
docker exec -it docker-api-1 bash -lc 'exec 3<>/dev/tcp/plugin_daemon/5003 && echo TCP:OK || echo TCP:NG'

# API が JSON を返すこと（Nginx 中継 OK）
curl -i http://localhost:3000/console/api/system-features | head -n 20
```

---

## 5. Apple Silicon の注意点（補足）

- 一部モデルで **Metal カーネル**が揃っておらず、**LLM Studio で推論が落ちる**ことがある。  
- **Ollama の量子化済みモデル（例：`q4_K_M`）**を優先。  
- LLM Studio を使うなら **モデルを替える**／**アップデート**／**設定見直し（CPU fallback など）**。

---

## 6. まとめ

- 今回の遅延は **ネットワーク境界（ホスト⇄Docker）**・**複数のエンドポイント種別（HTTP と TCP）**・**URL 末尾 `/v1` の仕様差**・**プロキシの中継先**・**ブラウザキャッシュ**など**環境組み合わせの罠**が主因。  
- 本ドキュメントの **チェックリストと TL;DR** を使えば、**再現時も短時間で復旧**できます。おつかれさまでした！
