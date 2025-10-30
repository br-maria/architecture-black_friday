#!/usr/bin/env bash
set -euo pipefail

# ---------- autodetect compose file ----------
find_compose() {
  if [[ -n "${COMPOSE_FILE:-}" ]]; then
    [[ -f "$COMPOSE_FILE" ]] || { echo " COMPOSE_FILE='$COMPOSE_FILE' не найден"; exit 1; }
    echo "docker compose -f ${COMPOSE_FILE}"
    return
  fi
  local base=""
  [[ -f ./scripts/compose.yaml ]] && base="./scripts/compose.yaml"
  [[ -z "$base" && -f ./compose.yaml ]] && base="./compose.yaml"
  [[ -z "$base" && -f ./docker-compose.yaml ]] && base="./docker-compose.yaml"
  [[ -z "$base" && -f ./scripts/docker-compose.yaml ]] && base="./scripts/docker-compose.yaml"
  [[ -n "$base" ]] || { echo " compose-файл не найден (искал: ./scripts/compose.yaml, ./compose.yaml, ./docker-compose.yaml, ./scripts/docker-compose.yaml)"; exit 1; }
  echo "docker compose -f ${base}"
}
DC="$(find_compose)"

# ---------- имена сервисов (как в `docker compose config --services`) ----------
CFG1="configsvr01"; CFG2="configsvr02"; CFG3="configsvr03"
S1A="shard01a"; S1B="shard01b"; S1C="shard01c"
S2A="shard02a"; S2B="shard02b"; S2C="shard02c"
REDIS="redis"
MONGOS="mongos"
APP="app"

# ---------- репликасеты и порты ----------
CFG_RS="cfgReplSet"
SHARD1_RS="shard01"
SHARD2_RS="shard02"

CFG_PORT=27019
SHARD_PORT=27018
MONGOS_PORT=27017
APP_PORT=${APP_PORT:-8080}

DB_NAME="${DB_NAME:-appdb}"
COLL_NAME="${COLL_NAME:-users}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

wait_ping() { # <svc> <port> [tries] [sleep]
  local svc="$1" port="$2" tries="${3:-90}" sleep_s="${4:-2}"
  for ((i=1;i<=tries;i++)); do
    if $DC exec -T "$svc" bash -lc "exec 3<>/dev/tcp/127.0.0.1/$port" >/dev/null 2>&1; then
      if $DC exec -T "$svc" bash -lc 'command -v mongosh >/dev/null 2>&1'; then
        if $DC exec -T "$svc" mongosh --port "$port" --quiet --eval 'db.runCommand({ping:1}).ok' | grep -q '^1$'; then
          return 0
        fi
      else
        # mongosh нет — но сокет слушает, считаем ок
        return 0
      fi
    fi
    sleep "$sleep_s"
  done
  return 1
}

wait_primary() { # <svc> <port> [tries] [sleep]
  local svc="$1" port="$2" tries="${3:-150}" sleep_s="${4:-2}"
  for ((i=1;i<=tries;i++)); do
    if $DC exec -T "$svc" mongosh --port "$port" --quiet --eval '
      try{
        const s = rs.status();
        if (s.ok === 1 && s.members && s.members.some(m => m.stateStr === "PRIMARY")) {
          const p = s.members.find(m => m.stateStr === "PRIMARY");
          if (p) print("PRIMARY:"+p.name); else print("PRIMARY:unknown");
        }
      }catch(e){}' | grep -q '^PRIMARY:'; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

run_mongo() { # <svc> <port> <js>
  local svc="$1" port="$2" js="$3"
  $DC exec -T "$svc" mongosh --port "$port" --quiet --eval "$js" >/dev/null
}

wait_http() { # <url> [tries] [sleep]
  local url="$1" tries="${2:-60}" sleep_s="${3:-2}"
  for ((i=1;i<=tries;i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep "$sleep_s"
  done
  return 1
}

# ---------- запуск базовых сервисов (без mongos и без app) ----------
log "1/6: docker compose up (без mongos и app)"
BASE_SERVICES=("$CFG1" "$CFG2" "$CFG3" "$S1A" "$S1B" "$S1C" "$S2A" "$S2B" "$S2C" "$REDIS")
$DC up -d --build "${BASE_SERVICES[@]}"

log "2/6: ждём mongod (config и shards)"
wait_ping "$CFG1" "$CFG_PORT" || { echo "[$CFG1] не отвечает"; exit 1; }
wait_ping "$S1A"  "$SHARD_PORT" || { echo "[$S1A] не отвечает"; exit 1; }
wait_ping "$S2A"  "$SHARD_PORT" || { echo "[$S2A] не отвечает"; exit 1; }

log "3/6: инициализация реплик (идемпотентно)"
# cfgRS
run_mongo "$CFG1" "$CFG_PORT" "
try{ rs.status().ok }catch(e){
  rs.initiate({
    _id: '$CFG_RS', configsvr: true,
    members: [
      { _id: 0, host: '$CFG1:$CFG_PORT' },
      { _id: 1, host: '$CFG2:$CFG_PORT' },
      { _id: 2, host: '$CFG3:$CFG_PORT' }
    ]
  })
}"
log "   ждём PRIMARY в $CFG_RS..."
wait_primary "$CFG1" "$CFG_PORT" || { echo "$CFG_RS не выбрал PRIMARY"; exit 1; }

# shard01
run_mongo "$S1A" "$SHARD_PORT" "
try{ rs.status().ok }catch(e){
  rs.initiate({
    _id: '$SHARD1_RS',
    members: [
      { _id: 0, host: '$S1A:$SHARD_PORT' },
      { _id: 1, host: '$S1B:$SHARD_PORT' },
      { _id: 2, host: '$S1C:$SHARD_PORT' }
    ]
  })
}"
log "   ждём PRIMARY в $SHARD1_RS..."
wait_primary "$S1A" "$SHARD_PORT" || { echo "$SHARD1_RS не выбрал PRIMARY"; exit 1; }

# shard02
run_mongo "$S2A" "$SHARD_PORT" "
try{ rs.status().ok }catch(e){
  rs.initiate({
    _id: '$SHARD2_RS',
    members: [
      { _id: 0, host: '$S2A:$SHARD_PORT' },
      { _id: 1, host: '$S2B:$SHARD_PORT' },
      { _id: 2, host: '$S2C:$SHARD_PORT' }
    ]
  })
}"
log "   ждём PRIMARY в $SHARD2_RS..."
wait_primary "$S2A" "$SHARD_PORT" || { echo "$SHARD2_RS не выбрал PRIMARY"; exit 1; }

# ---------- запускаем mongos, ждём его, подключаем шарды ----------
log "4/6: запускаем и ждём mongos"
$DC up -d "$MONGOS"
wait_ping "$MONGOS" "$MONGOS_PORT" || { echo "[mongos] не отвечает"; exit 1; }

log "5/6: добавляем шарды и включаем шардинг (идемпотентно)"
run_mongo "$MONGOS" "$MONGOS_PORT" "try{ sh.addShard('$SHARD1_RS/$S1A:$SHARD_PORT,$S1B:$SHARD_PORT,$S1C:$SHARD_PORT') }catch(e){}"
run_mongo "$MONGOS" "$MONGOS_PORT" "try{ sh.addShard('$SHARD2_RS/$S2A:$SHARD_PORT,$S2B:$SHARD_PORT,$S2C:$SHARD_PORT') }catch(e){}"
run_mongo "$MONGOS" "$MONGOS_PORT" "try{ sh.enableSharding('$DB_NAME') }catch(e){}"
run_mongo "$MONGOS" "$MONGOS_PORT" "try{ sh.shardCollection('$DB_NAME.$COLL_NAME', { _id: 'hashed' }) }catch(e){}"
$DC exec -T "$MONGOS" mongosh --port "$MONGOS_PORT" --quiet --eval 'sh.status().shards' || true

# ---------- приложение ----------
log "6/6: запускаем app/redis (на случай, если стартовали раньше mongos)"
$DC up -d "$APP" "$REDIS"

# uvicorn-ловушка
if $DC logs --no-color "$APP" 2>&1 | grep -q "Error: Got unexpected extra argument (app:app)"; then
  echo "Обнаружен конфликт ENTRYPOINT/command для uvicorn."
  echo "   Оставьте в compose у сервиса app только аргументы: command: [\"app:app\",\"--host\",\"0.0.0.0\",\"--port\",\"8080\"]"
  exit 1
fi

# ---------- проверка HTTP ----------
echo
log "Проверка приложения по HTTP…"
if wait_http "http://localhost:${APP_PORT}/" 30 1; then
  echo "app отвечает на /"
else
  echo "app пока не отвечает на / (это не ошибка, если root-эндпойнта нет)"
fi

if wait_http "http://localhost:${APP_PORT}/users" 30 1; then
  echo "app отвечает на /users"
  curl -s -w "\nfirst:  %{time_total}s\n"  -o /dev/null "http://localhost:${APP_PORT}/users" || true
  curl -s -w "\nsecond: %{time_total}s\n" -o /dev/null "http://localhost:${APP_PORT}/users" || true
else
  echo "/users недоступен — пропускаем замер кэша"
fi

$DC ps
echo
log "Готово!"
