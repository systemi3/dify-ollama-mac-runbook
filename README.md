# Dify × Ollama ローカル構築ランブック

Mac / Apple Silicon で **Dify** と **Ollama** を完全ローカルで動かすための実践ドキュメント集です。
実際に遭遇したエラーと、その解決に至るまでの記録をまとめています。

- クラウド課金なしで Dify のワークフローを動かす
- Ollama を OpenAI 互換エンドポイントとして Dify に接続する
- Nginx ゲートウェイでフロントと API の経路不整合を解消する

---

## 全体構成（開発環境全体）

```
                                 ┌────────────────────────────┐
                                 │            ユーザー         │
                                 │  ブラウザ / VS Code / curl │
                                 └─────────────┬──────────────┘
                                               │
                           HTTP                 │
                     (3000/3001/8000)          │
                                               │
                ┌──────────────┬───────────────┴───────────────┐
                │              │                               │
        (A) Next.js         (B) FastAPI                    (C) Dify Console
          Web テンプレ        AI テンプレ                  http://localhost:3000
        :3000/3001             :8000                               │
           │                    │                                  │
           └───────────────(開発用/任意連携)──────────────────────┘
                                │                                  │
                                └───────(REST)─────────────────────┘
                                                     Dify API
                                                              │
                                                              │  (compose 内ネットワーク)
                                                              ▼
     ┌─────────────────────────────────────────────────────────────────────────────────────┐
     │                         Docker 環境（どちらか片方で稼働）                            │
     │                                                                                      │
     │  ┌─────────────────────────────┐                 ┌──────────────────────────────┐     │
     │  │      Colima (軽量/既定)     │   ← dcolima →   │  Docker Desktop (GUI/補助)  │     │
     │  │  VM: vz / aarch64           │   ← ddesktop →  │  VM: Apple HVF               │     │
     │  └───────────┬─────────────────┘                 └───────────┬──────────────────┘     │
     │              │                                                │                        │
     │              └─────(DOCKER_HOST の向き先をスクリプトでトグル)──────┬───────────────────┘
     │                                                                    │
     │                          ┌──────────────┐  ┌────────────┐  ┌───────────────┐           │
     │                          │  dify-web    │  │  dify-api  │  │  worker       │           │
     │                          └───────┬──────┘  └────┬───────┘  └───────┬───────┘           │
     │                                  │              │                  │                   │
     │                ┌─────────────────▼──────┐  ┌───▼─────────┐  ┌─────▼──────┐             │
     │                │   PostgreSQL 15        │  │   Redis 7   │  │  ベクトルDB │             │
     │                └─────────────────────────┘  └─────────────┘  └────────────┘             │
     └─────────────────────────────────────────────────────────────────────────────────────┘

  (D) ローカル推論サーバ（Ollama / LM Studio）
      ┌────────────────────────────────────────────────────────────────┐
      │  macOS ホストで稼働                                            │
      │  Dify の「モデルプロバイダ」Base URL → http://host.docker.internal:PORT │
      └────────────────────────────────────────────────────────────────┘
```

> この図は開発環境全体の見取り図です（Colima / Docker Desktop の二刀流、Next.js・FastAPI テンプレートを含む）。
> **本リポジトリが対象とするのは、このうち Dify + Ollama の部分**です。実際に構築する構成は次の通りです。

### 本リポジトリが対象とする構成

```
[ブラウザ] -- http://localhost:3000
        │
      [gateway(Nginx)]  ← 3000:80
        ├── /                → web:3000   (静的フロント)
        ├── /console/api/    → api:5001   (Dify Console API)
        └── /api/            → api:5001   (Public API/任意)
[Docker]
  ├─ web / api / db(postgres) / redis / sandbox
  └─ plugin_daemon   5002(HTTP) + 5003(gnet)
[ホスト]
  └─ Ollama サーバ: 0.0.0.0:11434
```

---

## ドキュメント

| ファイル | 内容 |
|---|---|
| [`docs/setup.md`](docs/setup.md) | **構築手順**。Ollama 常駐 → `.env` → Nginx → 起動 → モデル登録 |
| [`docs/operations.md`](docs/operations.md) | **日常運用**。再起動ルーチン、ヘルスチェック、モデル名 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | **トラブル対処**。症状別14件と切り分けの順番 |
| [`docs/postmortem.md`](docs/postmortem.md) | **ポストモーテム**。なぜ時間がかかったのかの記録 |

### 目的別の入口

- **これから構築する** → [`setup.md`](docs/setup.md)
- **毎日使う / 再起動した** → [`operations.md`](docs/operations.md)
- **エラーが出た** → [`troubleshooting.md`](docs/troubleshooting.md)
- **経緯と判断理由を知りたい** → [`postmortem.md`](docs/postmortem.md)

---

## 設定値の正本について

**`docs/postmortem.md` が設定値の唯一の正本です。**

このリポジトリはローカルの Obsidian Vault から取り込んだ複数のランブックを統合したもので、原本どうしに食い違いがありました。postmortem は問題が解決した後に書かれた記録であり、動作実績のある値を含むため、矛盾はすべて postmortem 側を採用しています。

特に注意が必要な2点です。

**1. Plugin Daemon は 5002 と 5003 の両方が必要**

```dotenv
PLUGINS_ENABLED=true
PLUGIN_DAEMON_URL=http://plugin_daemon:5002   # HTTP 用
PLUGIN_DAEMON_HOST=plugin_daemon:5003         # gnet/TCP 用
```

`PLUGIN_DAEMON_URL` を空文字で上書きすると Pydantic のバリデーションに弾かれ、API が再起動ループに入ります。原本にはこれを推奨する誤った記述がありましたが、[`troubleshooting.md` 1.3](docs/troubleshooting.md) に誤りとして記録してあります。

**2. `proxy_pass` の末尾スラッシュは必須**

```nginx
proxy_pass http://web:3000/;
proxy_pass http://api:5001/console/api/;
proxy_pass http://api:5001/api/;
```

省略すると URI 置換が効かず、意図しない経路になります。

---

## 構成図の生成（bootstrap-diagram-kit.sh）

構成図を Mermaid 形式で生成し、SVG / PNG にレンダリングするためのキットを作成するスクリプトです。

### 実行

```bash
chmod +x bootstrap-diagram-kit.sh
./bootstrap-diagram-kit.sh
```

`~/Downloads/diagram-kit/` に次の4ファイルと、`~/Downloads/diagram-kit.tar.gz` が生成されます。

| ファイル | 役割 |
|---|---|
| `diagram.mmd` | Mermaid 形式の構成図 |
| `render-diagram.sh` | SVG / PNG へのレンダリング |
| `Makefile` | `make svg` / `make png` / `make all` / `make clean` |
| `README.md` | キット自体の説明 |

> **出力先は `~/Downloads/diagram-kit` に固定されています。** 変更する場合はスクリプト 4 行目の `BASE` を編集してください。

### レンダリング

生成されたディレクトリに移動して実行します。Docker と NPM のどちらかがあれば動作します（Docker 優先）。

```bash
cd ~/Downloads/diagram-kit

# Docker（推奨）
make docker-pull    # minlag/mermaid-cli を取得
make all            # diagram.svg / diagram.png を生成

# または NPM
npm install -g @mermaid-js/mermaid-cli
make all
```

どちらも無い場合はレンダリング手段が見つからない旨のメッセージが出て終了します。

---

## 原本ファイル

`docs/` 配下は、リポジトリ直下の以下の原本を統合・再編したものです。原本は履歴と照合できるよう残してあります。

| ファイル | 行数 | 統合先 |
|---|---|---|
| `dify-ollama-runbook.md` | 373 | setup / operations / troubleshooting |
| `dify_ollama_local_runbook_ja.md` | 265 | setup / operations |
| `architecture.md` | 86 | README（全体構成図） |
| `dify_cloud_inference_setup.md` | 133 | **未統合**（下記参照） |
| `bootstrap-diagram-kit.sh` | 191 | そのまま実行可能 |

### `dify_cloud_inference_setup.md` を統合していない理由

**未検証の別トピックであるため**、原本のまま残しています。

本リポジトリの `docs/` は「ローカル完結（Dify + ホスト常駐 Ollama）」の構成を扱い、記載された設定値はすべて [`postmortem.md`](docs/postmortem.md) の動作実績に裏付けられています。

一方このファイルは **ローカル Dify + クラウド推論**という別構成のガイドで、外部の推論エンドポイントに接続する手順が中心です。ローカル構成とは前提が異なり、かつ動作実績の記録がありません。検証済みの内容と混在させると、どこまでが実績に基づく記述か区別できなくなるため、統合を見送りました。

検証が済んだ段階で `docs/cloud-inference.md` として加える余地はあります。

---

## 動作確認環境

| 項目 | バージョン |
|---|---|
| macOS | Apple Silicon（M2 以降） |
| Dify | 1.7.2 |
| Ollama | 0.11.4 |
| モデル | `llama3.2:3b-instruct-q4_K_M` / `nomic-embed-text:latest` |
