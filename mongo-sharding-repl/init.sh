#!/usr/bin/env bash
set -euo pipefail

DC="docker compose"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

wait_ping() {
  # wait_ping <service> <port> <retries> <sleep_sec>
  local svc="$1" port="$2" tries="${3:-60}" sleep_s="${4:-2}"
  for ((i=1;i<=tries;i++)); do
    if $DC exec -T "$svc" mongosh --port "$port" --quiet --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

wait_primary() {
  # wait_primary <service> <port> <retries> <sleep_sec>
  local svc="$1" port="$2" tries="${3:-60}" sleep_s="${4:-2}"
  for ((i=1;i<=tries;i++)); do
    if $DC exec -T "$svc" mongosh --port "$port" --quiet --eval 'rs.isMaster().ismaster' | grep -q '^true$'; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

log "1/4: запуск docker compose"
$DC up -d

log "2/4: инициализация cfgRS"
wait_ping config1 27019 || { echo "config1 не отвечает"; exit 1; }
$DC exec -T config1 mongosh --port 27019 --quiet --eval 'try{
  rs.initiate({
    _id: "cfgRS",
    configsvr: true,
    members: [
      { _id: 0, host: "config1:27019", priority: 2 },
      { _id: 1, host: "config2:27019", priority: 1 },
      { _id: 2, host: "config3:27019", priority: 1 }
    ]
  })
}catch(e){ print(e) }'
wait_primary config1 27019 || { echo "cfgRS не выбрал PRIMARY"; exit 1; }

log "2/4: инициализация shard1RS"
wait_ping shard1-1 27018 || { echo "shard1-1 не отвечает"; exit 1; }
$DC exec -T shard1-1 mongosh --port 27018 --quiet --eval 'try{
  rs.initiate({
    _id: "shard1RS",
    members: [
      { _id: 0, host: "shard1-1:27018", priority: 2 },
      { _id: 1, host: "shard1-2:27018", priority: 1 },
      { _id: 2, host: "shard1-3:27018", priority: 1 }
    ]
  })
}catch(e){ print(e) }'
wait_primary shard1-1 27018 || { echo "shard1RS не выбрал PRIMARY"; exit 1; }

log "2/4: инициализация shard2RS"
wait_ping shard2-1 27018 || { echo "shard2-1 не отвечает"; exit 1; }
$DC exec -T shard2-1 mongosh --port 27018 --quiet --eval 'try{
  rs.initiate({
    _id: "shard2RS",
    members: [
      { _id: 0, host: "shard2-1:27018", priority: 2 },
      { _id: 1, host: "shard2-2:27018", priority: 1 },
      { _id: 2, host: "shard2-3:27018", priority: 1 }
    ]
  })
}catch(e){ print(e) }'
wait_primary shard2-1 27018 || { echo "shard2RS не выбрал PRIMARY"; exit 1; }

log "3/4: ожидание mongos"
ok=0
for i in {1..90}; do
  if $DC exec -T mongos mongosh --quiet --eval 'db.adminCommand("ping").ok' >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 2
done
[[ "$ok" = 1 ]] || { echo "mongos не отвечает"; exit 1; }

log "4/4: добавление шардов и шардирование коллекции"
$DC exec -T mongos mongosh --quiet --eval 'try{ sh.addShard("shard1RS/shard1-1:27018,shard1-2:27018,shard1-3:27018") }catch(e){ print(e) }'
$DC exec -T mongos mongosh --quiet --eval 'try{ sh.addShard("shard2RS/shard2-1:27018,shard2-2:27018,shard2-3:27018") }catch(e){ print(e) }'
$DC exec -T mongos mongosh --quiet --eval 'try{ sh.enableSharding("somedb") }catch(e){ print(e) }'
$DC exec -T mongos mongosh --quiet --eval 'try{ sh.shardCollection("somedb.helloDoc", { _id: "hashed" }) }catch(e){ print(e) }'

log "готово"
