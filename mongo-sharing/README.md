# MongoDB Sharding — кластер в Docker Compose

## Обзор
Проект разворачивает шардированный кластер MongoDB:
- Config Server (`cfgRS`)
- Два шарда (`shard1RS`, `shard2RS`)
- Маршрутизатор `mongos` (порт 27017)
- Пример БД `somedb` и коллекции `helloDoc`, шардирование по `{ _id: 'hashed' }`

## Требования
- Docker + Docker Compose v2
- Папка проекта: `mongo-sharing` (файл `compose.yaml` внутри)

---

## Быстрый запуск (idempotent — можно выполнять повторно)

### 1) Перейти в проект
```bash
cd mongo-sharing
```

### 2) (Опционально) Чистый старт, если уже что-то поднималось раньше
```bash
docker compose down --remove-orphans
docker volume rm mongo-sharding_cfg_data mongo-sharding_shard1_data mongo-sharding_shard2_data 2>/dev/null || true
```

### 3) Запуск контейнеров
```bash
docker compose up -d
```

### 4) Инициализация кластера (обязательно выполнить; команды идемпотентные)

**4.1 Config Server → cfgRS (ожидаем PRIMARY)**
```bash
docker compose exec -T configsvr mongosh --port 27019 --quiet <<'EOF'
try { rs.initiate({_id:"cfgRS", configsvr:true, members:[{_id:0, host:"configsvr:27019"}]}) } catch(e) {}
while (!rs.isMaster().ismaster) { sleep(500) }
print("cfgRS PRIMARY READY; setName=", db.isMaster().setName)
EOF
```

**4.2 Шарды → single-node RS и ожидание PRIMARY**
```bash
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
try { rs.initiate({_id:"shard1RS", members:[{_id:0, host:"shard1:27018"}]}) } catch(e) {}
while (!rs.isMaster().ismaster) { sleep(500) }
print("shard1RS PRIMARY READY")
EOF

docker compose exec -T shard2 mongosh --port 27018 --quiet <<'EOF'
try { rs.initiate({_id:"shard2RS", members:[{_id:0, host:"shard2:27018"}]}) } catch(e) {}
while (!rs.isMaster().ismaster) { sleep(500) }
print("shard2RS PRIMARY READY")
EOF
```

**4.3 Подключение шардов, включение шардирования БД и коллекции**
```bash
docker compose exec -T mongos mongosh --host 127.0.0.1 --port 27017 --quiet <<'EOF'
sh.addShard("shard1RS/shard1:27018")
sh.addShard("shard2RS/shard2:27018")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { _id: "hashed" })
print("SHARDING READY")
EOF
```

### 5) Проверка статуса кластера
```bash
docker compose exec -T mongos mongosh --host 127.0.0.1 --port 27017 --eval "sh.status()"
```

---

## Тест распределения данных

### Вариант A — небольшая проверка
```bash
docker compose exec -T mongos mongosh --host 127.0.0.1 --port 27017 --quiet <<'EOF'
use somedb
db.helloDoc.deleteMany({})
db.helloDoc.insertMany(Array.from({length:10},(_,i)=>({_id:i,msg:"hi-"+i})))
print("count:", db.helloDoc.countDocuments())
db.helloDoc.getShardDistribution()
EOF
```

### Вариант B — 20k документов батчами (быстрее)
```bash
docker compose exec -T mongos mongosh --host 127.0.0.1 --port 27017 --quiet <<'EOF'
use somedb
db.helloDoc.deleteMany({})
const BATCH=1000, TOTAL=20000;
for (let start=0; start<TOTAL; start+=BATCH) {
  const docs = [];
  for (let i=0; i<BATCH; i++) docs.push({_id:start+i, msg:"hi-"+(start+i)});
  db.helloDoc.insertMany(docs, {ordered:false});
  print("inserted:", start+BATCH);
}
print("final:", db.helloDoc.countDocuments())
db.helloDoc.getShardDistribution()
EOF
```

Ожидаемо: примерно 50/50 по `shard1RS` и `shard2RS`.

---

## Строка подключения приложения
```
mongodb://mongos:27017/somedb
```

---

## Диагностика (когда что-то не отвечает)

**Проверить, что все контейнеры живы:**
```bash
docker compose ps
```

**Если `mongos` не отвечает (`ECONNREFUSED`) — убедись, что cfgRS инициализирован и есть PRIMARY, затем перезапусти `mongos`:**
```bash
docker compose exec -T configsvr mongosh --port 27019 --quiet --eval 'db.isMaster().setName; rs.isMaster().ismaster'
docker compose restart mongos
docker compose exec -T mongos mongosh --host 127.0.0.1 --port 27017 --eval 'db.adminCommand("ping")'
```

**Если `sh.status()` пишет `No shards found` — повтори шаг 4.3 (addShard/enableSharding/shardCollection).**

**Полный сброс (начать с нуля):**
```bash
docker compose down --remove-orphans
docker volume rm mongo-sharding_cfg_data mongo-sharding_shard1_data mongo-sharding_shard2_data
docker compose up -d
```

---

## Примечания
- Все команды инициализации выше **идемпотентны** — можно запускать повторно.
- Порты по умолчанию: `mongos:27017`, `shards:27018`, `configsvr:27019`.
- БД: `somedb`, коллекция: `helloDoc`, шардирование по `{ _id: 'hashed' }`.
