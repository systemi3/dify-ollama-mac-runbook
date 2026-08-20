# 二刀流 (Colima / Docker Desktop) + Dify + Web/AI 開発構成まとめ

## 概要
- **二刀流運用**：Colima (軽量/安定) と Docker Desktop (GUI/補助) を `two-swords.sh` で切替。
- **Difyローカル構成**：PostgreSQL, Redis, Qdrant, MinIO, Dify(api/web/worker/plugin_daemon)、Sandbox(任意)。
- **Webテンプレ**：Next.js (3000/3001)。
- **AIテンプレ**：FastAPI (8000)。
- **LM Studio**：ホストで稼働 (:1234)、Difyのモデルプロバイダから `http://host.docker.internal:1234` で接続。

## 構成図

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
      ~/Projects/web      ~/Projects/ai/app               http://localhost:3000
        :3000/3001             :8000                               │
           │                    │                                  │
           │                    │                                  │
           └───────────────(開発用/任意連携)──────────────────────┘
                                │                                  │
                                └───────(REST)─────────────────────┘
                                                     Dify API :8080
                                                     http://localhost:8080
                                                              │
                                                              │  (compose 内ネットワーク: dify_net)
                                                              ▼
     ┌─────────────────────────────────────────────────────────────────────────────────────┐
     │                         Docker 環境（どちらか片方で稼働）                            │
     │                                                                                      │
     │  ┌─────────────────────────────┐                 ┌──────────────────────────────┐     │
     │  │      Colima (軽量/既定)     │   ← dcolima →   │  Docker Desktop (GUI/補助)  │     │
     │  │  VM: vz / aarch64           │   ← ddesktop →  │  VM: Apple HVF               │     │
     │  └───────────┬─────────────────┘                 └───────────┬──────────────────┘     │
     │              │                                                │                        │
     │              └─────(DOCKER_HOST の向き先を two-swords.sh でトグル)───────┬───────────────┘
     │                                                                          │
     │                                ┌──────────────────────────────────────────┴─────────────────────────────────┐
     │                                │                                 docker compose (~/Projects/infra/dify)      │
     │                                │  ports: 3000,8080,9000,9001,6333                                           │
     │                                │  volumes: ./volumes/...                                                    │
     │                                └────────────────────────────────────────────────────────────────────────────┘
     │                                     │          │           │            │           │
     │                                     │          │           │            │           │
     │                          ┌──────────▼───┐  ┌───▼────────┐ ├────────────▼───┐  ┌────▼─────┐
     │                          │  dify-web    │  │  dify-api  │ │  worker       │  │ sandbox* │
     │                          │ (Console:3000)│ │ (API:8080) │ │ (jobs/queues) │  │ (任意)   │
     │                          └───────┬──────┘  └────┬───────┘ └───────┬───────┘  └────┬─────┘
     │                                  │               │                   │               │
     │                                  │               │                   │               │
     │                ┌─────────────────▼──────┐   ┌───▼─────────┐   ┌─────▼──────┐   ┌───▼─────────┐
     │                │   PostgreSQL 15        │   │   Redis 7    │   │  Qdrant     │   │  MinIO(S3)  │
     │                │  (DB: dify)            │   │ (cache/queue)│   │ (vector DB) │   │ (files)     │
     │                │  port: 内部のみ        │   │ 6379         │   │ 6333        │   │ 9000/9001   │
     │                │  vol: ./volumes/postgres│  │ vol: ./volumes/redis │ vol: ./volumes/qdrant │ vol: ./volumes/minio │
     │                └─────────────────────────┘   └─────────────┘   └────────────┘   └─────────────┘
     └─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  (D) LM Studio（ローカル推論サーバ）
      ┌────────────────────────────────────────────────────────────────┐
      │  macOSホストで稼働 :1234                                      │
      │  Difyの「モデルプロバイダ」Base URL → http://host.docker.internal:1234 │
      └────────────────────────────────────────────────────────────────┘
```

## 運用ポイント
- Colima: 普段使い（軽量・安定）  
- Docker Desktop: GUIやチーム統一が必要な時だけ  
- Dify: `cd ~/Projects/infra/dify && make up`  
- Next.js: `make web-init-next && make web-run`  
- FastAPI: `make ai-init && make ai-run`  
- LM Studio: Base URL = `http://host.docker.internal:1234`

## 注意点
- ColimaとDesktopは**同時起動しない**  
- 24GB MacBook Airでは、Colimaメモリを8GB→必要時12GBまで  
- DifyとNext.jsはポート3000競合 → Next.jsを`3001`に変更推奨

