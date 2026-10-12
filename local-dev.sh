#!/usr/bin/env bash
# 沙箱本地开发环境一键搭建/恢复脚本（非 Docker 部署）。
# 远程沙箱容器会被重新调度：/workspace 持久，但系统包、PostgreSQL 数据、node_modules 之外的进程都会丢。
# 用法：
#   bash local-dev.sh up        搭建并后台启动 api/worker/web
#   bash local-dev.sh down      停止三个服务
#   bash local-dev.sh logs      跟踪日志
#   bash local-dev.sh status    查看状态
# 可选：LLM_API_KEY=sk-xxx LLM_MODEL=xxx bash local-dev.sh up
set -euo pipefail
cd /workspace

DB_NAME=myhot
DB_USER=myhot
DB_PASS=myhot_pass
LOG_DIR=/workspace/.data/logs
PID_DIR=/workspace/.data/pids
mkdir -p "$LOG_DIR" "$PID_DIR" /workspace/.data

export DATABASE_URL="postgres://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"

start_pg() {
  if ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
    service postgresql start >/dev/null 2>&1 || true
    sleep 2
  fi
}

ensure_db() {
  start_pg
  # 用 DO 块做幂等创建，避免 su 登录 shell 的噪声输出和引号转义问题
  local sql; sql=$(mktemp)
  cat > "$sql" <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}' CREATEDB SUPERUSER;
  END IF;
END \$\$;
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='${DB_NAME}')\gexec
SQL
  su - postgres -c "psql -v ON_ERROR_STOP=0 -f '$sql'" >/dev/null 2>&1 || true
  rm -f "$sql"
}

ensure_env() {
  if [ ! -f .env ]; then
    node scripts/init-env.ts --llm-key "${LLM_API_KEY:-}" >/dev/null
  fi
  # 非 Docker 本地运行需要的设置（幂等写入）
  grep -q '^DATABASE_URL=' .env || echo "DATABASE_URL=${DATABASE_URL}" >> .env
  grep -q '^API_BASE_URL=' .env || echo 'API_BASE_URL=http://127.0.0.1:3001' >> .env
  grep -q '^WEB_HOST=' .env || echo 'WEB_HOST=0.0.0.0' >> .env
  grep -q '^DEV_AUTH_ROLE=' .env || echo 'DEV_AUTH_ROLE=admin' >> .env
  grep -q '^DEV_AUTH_DISPLAY_NAME=' .env || echo 'DEV_AUTH_DISPLAY_NAME="Dev Admin"' >> .env
  # 沙箱出口：平台封了框架依赖的 cloudflare DoH，IP 钉连不可用；关闭自带 dispatcher，
  # 改用全局 EnvHttpProxyAgent（由 scripts/sandbox-global-proxy.cjs 注入）走平台代理。
  grep -q '^ALLOW_PRIVATE_NETWORK_FETCH=' .env || echo 'ALLOW_PRIVATE_NETWORK_FETCH=true' >> .env
  # 安全阀：没有真实 LLM Key 前保持关闭；提供了 LLM_API_KEY 则打开
  if [ -n "${LLM_API_KEY:-}" ]; then
    sed -i 's/^COLLECT_ENABLED=.*/COLLECT_ENABLED=true/; s/^MODEL_CALLS_ENABLED=.*/MODEL_CALLS_ENABLED=true/' .env
  else
    sed -i 's/^COLLECT_ENABLED=.*/COLLECT_ENABLED=false/; s/^MODEL_CALLS_ENABLED=.*/MODEL_CALLS_ENABLED=false/' .env
  fi
}

migrate_seed() {
  # Node 24.1.0 的 import.meta.main 为 undefined（项目要求 >=24.11），migrate.ts 主入口不会执行，
  # 因此直接内联调用 runMigrations。
  node --input-type=module -e "
    import { runMigrations } from './scripts/migrate.ts';
    import { closeDb, sql } from '@aihot/backend/db';
    import { REPO_ROOT } from '@aihot/backend/config';
    try { await runMigrations(sql, REPO_ROOT); } finally { await closeDb(); }
  " 2>&1 | grep -vE 'ExperimentalWarning|trace-warnings' || true
  # 种子幂等（信源已存在时输出 added 0）
  node scripts/seed.ts 2>&1 | grep -E '^sources:' || true
}

build_web() {
  if [ ! -f apps/web/build/server/index.js ]; then
    npm run build -w @aihot/web >/tmp/web-build.log 2>&1
  fi
}

start_svc() {
  local name=$1 dir=$2 cmd=$3
  local pidfile="$PID_DIR/$name.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "$name already running (pid $(cat "$pidfile"))"
    return
  fi
  (
    cd "$dir"
    set -a; source /workspace/.env; set +a
    nohup bash -c "$cmd" >"$LOG_DIR/$name.log" 2>&1 &
    echo $! >"$pidfile"
  )
  echo "$name started (pid $(cat "$pidfile"))"
}

up() {
  ensure_db
  ensure_env
  migrate_seed
  build_web
  start_svc api /workspace 'node apps/api/src/main.ts'
  start_svc worker /workspace 'node apps/worker/src/main.ts'
  start_svc web /workspace/apps/web 'node server.ts'
  sleep 3
  status
}

down() {
  for name in web worker api; do
    local pidfile="$PID_DIR/$name.pid"
    if [ -f "$pidfile" ]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
      rm -f "$pidfile"
      echo "$name stopped"
    fi
  done
}

status() {
  for name in api worker web; do
    local pidfile="$PID_DIR/$name.pid"
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo "$name: RUNNING (pid $(cat "$pidfile"))"
    else
      echo "$name: STOPPED"
    fi
  done
  curl -s -m 3 -o /dev/null -w 'web http://localhost:3000 -> %{http_code}\n' http://127.0.0.1:3000/ || true
}

setup() {
  ensure_db
  ensure_env
  migrate_seed
  build_web
  echo "setup complete; start services with: bash local-dev.sh start (or as foreground processes)"
}

case "${1:-up}" in
  setup) setup ;;
  run)
    # 前台运行单个服务（沙箱里后台进程会被回收，用长驻命令方式启动）：bash local-dev.sh run api|worker|web
    set -a; source /workspace/.env; set +a
    export NODE_OPTIONS="${NODE_OPTIONS:-} --require /workspace/scripts/sandbox-global-proxy.cjs"
    case "$2" in
      api) exec node apps/api/src/main.ts ;;
      worker) exec node apps/worker/src/main.ts ;;
      web) cd apps/web && exec node server.ts ;;
      *) echo "usage: bash local-dev.sh run api|worker|web" ;;
    esac ;;
  up) up ;;
  down) down ;;
  status) status ;;
  logs) tail -f "$LOG_DIR"/*.log ;;
  *) echo "usage: bash local-dev.sh [setup|up|down|status|logs]" ;;
esac
