# 日常運用（Operations）

構築済みの環境を毎日使うための手順です。初回構築は [`setup.md`](setup.md) を参照してください。

---

## 1. 再起動ルーチン（毎回これだけ）

Mac を再起動した後などは、この3ステップで復帰します。

```bash
# 1) Ollama（Mac 側）
pkill -f "ollama serve" || true
OLLAMA_HOST=0.0.0.0:11434 /opt/homebrew/bin/ollama serve > ~/.ollama-serve.log 2>&1 &
sleep 2

# 2) Dify（Docker 側）
cd "$COMPOSE_DIR"
docker compose up -d gateway api web plugin_daemon

# 3) ヘルス確認
curl -sS http://localhost:3000/console/api/system-features | head -n 1
docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
```

> Ollama は `brew services` に登録していない限り、再起動のたびに手動起動が必要です。

`$COMPOSE_DIR` が分からなくなったときの逆引き:

```bash
COMPOSE_DIR=$(docker inspect docker-api-1 --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
echo "Compose dir: $COMPOSE_DIR"
```

---

## 2. ヘルスチェック（4コマンド）

上から順に実行すると、どの層で止まっているかが切り分けられます。

```bash
# 1) Ollama 起動確認
lsof -nP -iTCP:11434 -sTCP:LISTEN && curl -sS http://127.0.0.1:11434/v1/models

# 2) コンテナ一覧
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# 3) ゲートウェイ → API の JSON 確認
curl -i http://localhost:3000/console/api/system-features | head -n 20

# 4) コンテナ内から Ollama 可視性確認
docker exec -it docker-api-1 bash -lc 'curl -sS http://host.docker.internal:11434/v1/models'
```

### 期待される結果

| # | 期待 | 外れたときの参照先 |
|---|---|---|
| 1 | `LISTEN` が出て `/v1/models` が JSON | [troubleshooting 1.1 / 1.2](troubleshooting.md) |
| 2 | `api` `web` `gateway` `plugin_daemon` が Up | [troubleshooting 1.3](troubleshooting.md) |
| 3 | `HTTP/1.1 200` かつ `application/json` | [troubleshooting 1.4](troubleshooting.md) |
| 4 | JSON でモデル一覧が返る | [troubleshooting 1.2](troubleshooting.md) |

### Plugin Daemon の変数確認

```bash
docker exec -it docker-api-1 bash -lc 'printenv | egrep -i "PLUGINS_ENABLED|PLUGIN_.*DAEMON"'
# 期待:
# PLUGINS_ENABLED=true
# PLUGIN_DAEMON_URL=http://plugin_daemon:5002
# PLUGIN_DAEMON_HOST=plugin_daemon:5003
```

---

## 3. よく使うモデル名

| 用途 | モデル名 |
|---|---|
| Chat | `llama3.2:3b-instruct-q4_K_M` |
| Embedding | `nomic-embed-text:latest` |

Apple Silicon で軽く動かすなら `q4_K_M` 量子化が無難です。さらに軽くする場合は `q3_K_L` や 1B / 2B 系を検討してください。クラッシュや極端な遅さが出たときは、まず量子化を軽くするかモデルを小さくします。

Dify に登録する際の API endpoint URL は `http://host.docker.internal:11434/v1`（**末尾 `/v1` 必須**）です。

---

## 4. トラブル調査用ワンライナー

```bash
# API / Web / ゲートウェイの状態だけ抜き出す
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | egrep 'docker-(api|web|gateway|plugin_daemon)-1'

# Web から API 経路が JSON かどうか
curl -i http://localhost:3000/console/api/system-features | head -n 10

# API コンテナ → Ollama 到達チェック（200 なら OK）
docker exec -it docker-api-1 bash -lc 'curl -i http://host.docker.internal:11434/v1/models | head -n1'

# エラーログの末尾
docker logs --tail=200 docker-api-1
docker logs --tail=200 docker-web-1
docker logs docker-plugin_daemon-1

# plugin/daemon 関連のエラーだけ絞る
docker logs docker-api-1 | egrep -i 'plugin|daemon|error' | tail -n 200

# Web の公開ポート確認（gateway 方式では :0 が正常）
docker compose port web 3000
```

> `docker compose port web 3000` が `:0` を返すのは**正常**です。本構成では `web` を直接公開せず、`gateway` の `3000:80` だけを外に出しています。

### 個別サービスの再作成

```bash
docker compose up -d --force-recreate api web gateway
```

---

## 5. 完全クリーンアップ（必要なときだけ）

```bash
# Ollama
brew services stop ollama || true
pkill -f "/opt/homebrew/.*/ollama serve" || true

# Dify（$COMPOSE_DIR で実行）
docker compose down -v     # ボリューム含め全削除（DB 初期化）注意！

# ブラウザ
# localhost:3000 / localhost:5001 のサイトデータを個別削除
```

> `docker compose down -v` は **DB を初期化します**。作成したアプリ・ワークフロー・アカウントがすべて消えます。実行前に必要性を確認してください。
