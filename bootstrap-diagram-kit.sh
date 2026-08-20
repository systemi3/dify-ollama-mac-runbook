#!/usr/bin/env bash
set -euo pipefail

BASE=~/Downloads/diagram-kit
mkdir -p "$BASE"

# diagram.mmd (Mermaid)
cat <<'MMD' > "$BASE/diagram.mmd"
%% diagram.mmd — 二刀流 + Dify + Web/AI + LM Studio 構成図 (Mermaid)
flowchart TB
  %% Clients
  U[["ユーザー<br/>Browser / VS Code / curl"]]

  %% Apps
  NX[("Next.js<br/>:3000 / :3001<br/>~/Projects/web")]
  FA[("FastAPI<br/>:8000<br/>~/Projects/ai/app")]
  DC[("Dify Console<br/>:3000")]

  U -->|HTTP 3000/3001| NX
  U -->|HTTP 8000| FA
  U -->|HTTP 3000| DC

  %% API
  API[("Dify API<br/>:8080")]
  DC -->|REST| API
  NX -. 任意REST .-> API
  FA -. REST .-> API

  %% Docker Layer Toggle
  subgraph DOCKER["Docker層（どちらか片方のみ稼働）"]
    direction LR
    subgraph COLIMA["Colima（軽量/既定）"]
      note1[["VM: vz / aarch64"]]
    end
    subgraph DESK["Docker Desktop（GUI/補助）"]
      note2[["VM: Apple HVF"]]
    end
  end

  %% Compose Network
  subgraph COMPOSE["docker compose（~/Projects/infra/dify, network: dify_net）"]
    direction TB
    WEB[("dify-web<br/>:3000")]
    WRK[("worker")]
    PLG[("plugin_daemon")]
    SBOX[("sandbox<br/>(profile: sandbox)")]

    DB[(("PostgreSQL 15<br/>vol: ./volumes/postgres"))]
    R[(("Redis 7<br/>vol: ./volumes/redis"))]
    Q[(("Qdrant<br/>:6333<br/>vol: ./volumes/qdrant"))]
    S3[(("MinIO (S3)<br/>:9000 / :9001<br/>vol: ./volumes/minio"))]

    WEB --> API
    WRK --> API
    PLG --> API

    API --> DB
    API --> R
    API --> Q
    API --> S3
  end

  %% Bindings
  classDef ext fill:#eef,stroke:#99f,stroke-width:1px;
  classDef svc fill:#efe,stroke:#6c6,stroke-width:1px;
  classDef store fill:#ffe,stroke:#cc6,stroke-width:1px;
  classDef box fill:#f5f5f5,stroke:#999,stroke-width:1px;

  class U ext
  class NX,FA,DC,WEB,API,WRK,PLG,SBOX svc
  class DB,R,Q,S3 store
  class DOCKER,COLIMA,DESK,COMPOSE box

  %% LM Studio
  LMS[["LM Studio<br/>ホスト: :1234"]]
  API -. "Base URL<br/>http://host.docker.internal:1234" .- LMS
MMD

# render-diagram.sh
cat <<'RS' > "$BASE/render-diagram.sh"
#!/usr/bin/env bash
set -euo pipefail
# render-diagram.sh — MermaidをSVG/PNGにレンダリング
# 優先: Docker(minlag/mermaid-cli) > mmdc(NPM)

MMD_FILE="${1:-diagram.mmd}"
OUT_SVG="${2:-diagram.svg}"
OUT_PNG="${3:-diagram.png}"

if ! test -f "$MMD_FILE"; then
  echo "[!] Mermaidファイルが見つかりません: $MMD_FILE" >&2
  exit 1
fi

render_with_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "[*] Docker + mermaid-cli でレンダリング"
    docker run --rm -u "$(id -u):$(id -g)" \
      -v "$PWD:/work" -w /work \
      minlag/mermaid-cli \
      -i "$MMD_FILE" -o "$OUT_SVG" -t default -b transparent
    docker run --rm -u "$(id -u):$(id -g)" \
      -v "$PWD:/work" -w /work \
      minlag/mermaid-cli \
      -i "$MMD_FILE" -o "$OUT_PNG" -t default -b transparent
    return 0
  fi
  return 1
}

render_with_npm() {
  if command -v mmdc >/dev/null 2>&1; then
    echo "[*] mmdc(NPM) でレンダリング"
    mmdc -i "$MMD_FILE" -o "$OUT_SVG" -t default -b transparent
    mmdc -i "$MMD_FILE" -o "$OUT_PNG" -t default -b transparent
    return 0
  fi
  return 1
}

if render_with_docker; then
  echo "[✓] 出力: $OUT_SVG, $OUT_PNG"
  exit 0
fi

if render_with_npm; then
  echo "[✓] 出力: $OUT_SVG, $OUT_PNG"
  exit 0
fi

cat <<'EOF' >&2
[!] レンダリング手段が見つかりません。
次のいずれかを用意してください。

(推奨) Docker: 
  docker pull minlag/mermaid-cli
  ./render-diagram.sh

または NPM:
  npm install -g @mermaid-js/mermaid-cli
  ./render-diagram.sh
EOF
exit 1
RS
chmod +x "$BASE/render-diagram.sh"

# Makefile
cat <<'MK' > "$BASE/Makefile"
# Makefile — Mermaid 図の生成
.PHONY: svg png all clean docker-pull

MMD=diagram.mmd
SVG=diagram.svg
PNG=diagram.png

all: svg png

svg:
	./render-diagram.sh $(MMD) $(SVG) $(PNG)

png:
	./render-diagram.sh $(MMD) $(SVG) $(PNG)

docker-pull:
	docker pull minlag/mermaid-cli

clean:
	rm -f $(SVG) $(PNG)
MK

# README
cat <<'RD' > "$BASE/README.md"
# Diagram Kit (Mermaid)
- `diagram.mmd` : Mermaid 形式の構成図
- `render-diagram.sh` : Docker または NPM(mmdc)で SVG/PNG 生成
- `Makefile` : `make svg` / `make png` / `make all` / `make clean`

## 使い方
### Docker（推奨）
make docker-pull
make all        # diagram.svg / diagram.png を生成

### NPM（mermaid-cli）
npm install -g @mermaid-js/mermaid-cli
make all
RD

# tar.gz も作成
cd ~/Downloads
tar -czf diagram-kit.tar.gz diagram-kit
echo "[✓] 作成しました: ~/Downloads/diagram-kit と ~/Downloads/diagram-kit.tar.gz"
