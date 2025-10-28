# Mongo Sharding + Репликация

## Описание проекта

Этот проект демонстрирует настройку **шардированного кластера MongoDB** с **репликацией**.  
Каждый шард (shard1RS, shard2RS) развёрнут в виде **Replica Set** из трёх узлов:  
один PRIMARY и два SECONDARY.  
Конфигурационные серверы (config1–3) объединены в отдельный Replica Set `cfgRS`.

Система собирается и инициализируется автоматически через `docker compose` и `make`.

---

## Требования

Перед началом можно проверить, что установлены:
- Docker ≥ 24
- Docker Compose ≥ 2.20
- GNU Make ≥ 4.0
- Порт **27017** (или **27027**) на хосте свободен

---

## Шаги запуска

**Перейти в каталог проекта:**
```bash
cd mongo-sharding-repl
```

**Запустить весь кластер:**
```bash
make up
```

Этот шаг:
- запускает все контейнеры MongoDB;
- инициализирует Replica Set для каждого шарда и config-сервера;
- запускает `mongos`;
- добавляет шарды в кластер и включает шардирование для БД `somedb`.

Среднее время развёртывания: 2–3 минуты.

---

## Проверка состояния

**Проверка статус всех Replica Set’ов:**
```bash
make status
```

Ожидаемый результат:
```
cfgRS: 1
s1-1: 1
s1-2: 2
s1-3: 2
s2-1: 1
s2-2: 2
s2-3: 2
```
Где:
- `1` — PRIMARY,
- `2` — SECONDARY.

---

## Тестирование кластера

**Запустить встроенный тест:**
```bash
make test
```

Что делает тест:
- очищает коллекцию `somedb.helloDoc`;
- вставляет 20 000 документов;
- выводит общее количество документов и распределение по шардам.

Ожидаемый результат:
```
Всего: 20000
Shard shard1RS ... docs: ~10000
Shard shard2RS ... docs: ~10000
```

---

## Проверка репликации вручную

**Проверить роли нод:**
```bash
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval 'printjson(rs.status().members.map(m=>({name:m.name,stateStr:m.stateStr})))'
```

**Добавить документ через mongos (PRIMARY):**
```bash
docker compose exec -T mongos mongosh --quiet --eval '
const d=db.getSiblingDB("somedb");
d.helloDoc.insertOne({_id:43000,msg:"replica-test"});
print("Inserted:", d.helloDoc.findOne({_id:43000}).msg);
'
```

**Проверить, где лежит документ:**
```bash
docker compose exec -T mongos mongosh --quiet --eval '
const d=db.getSiblingDB("somedb");
printjson(d.helloDoc.find({_id:43000}).explain("executionStats").queryPlanner.winningPlan.shards);
'
```

**Прочитать документ с SECONDARY на этом шарде:**
```bash
docker compose exec -T shard2-2 mongosh --port 27018 --quiet --eval '
db.getMongo().setReadPref("secondaryPreferred");
const d=db.getSiblingDB("somedb");
print("Secondary sees:", d.helloDoc.findOne({_id:43000})?.msg);
'
```

---

## Проверка отказоустойчивости

```bash
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval 'rs.stepDown(60)'
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval 'printjson(rs.status().members.map(m=>({name:m.name,stateStr:m.stateStr})))'
```

Ожидаемый результат:
```
shard1-2: PRIMARY
shard1-1: SECONDARY
```

---

##Завершение работы

```bash
make down
```

---

