# Sharding + Replica + Cache Demo

Проект демонстрирует полный стек:
- Шардированный кластер MongoDB (2 шарда × 3 реплики + 3 config-сервера + mongos router)  
- Redis для кэширования  
- Приложение на FastAPI (порт 8080)  
- Полная автоматизация запуска через один скрипт `init.sh`

---

## Структура проекта

```
.
├── api_app/
│   ├── app.py                # FastAPI приложение
│   ├── requirements.txt
│   └── Dockerfile
├── compose.yaml              # docker compose для всех сервисов
└── init.sh                   # единый сценарий запуска и инициализации
```


---

## Быстрый старт

1. Сделать скрипт исполняемым:
   ```bash
   chmod +x ./init.sh
   ```

2. Запустить всё одной командой:
   ```bash
   ./init.sh
   ```

   Скрипт автоматически:
   - соберёт и запустит все контейнеры;
   - инициализирует реплики config- и shard-кластеров;
   - подключит шарды к `mongos`;
   - включит шардирование для базы `somedb` и коллекции `helloDoc`;
   - перезапустит `app` и `redis` после готовности кластера;
   - проверит доступность API по HTTP.

3. Проверить состояние сервисов:
   ```bash
   docker compose ps
   ```

   Все контейнеры должны быть в состоянии `Up`, `mongos` — `healthy`.

---

## Проверка MongoDB

Посмотреть шард-конфигурацию:
```bash
docker compose exec -T mongos mongosh --port 27017 --quiet --eval 'sh.status().shards'
```

Создать тестовые данные:
```bash
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
for (let i=0;i<10;i++) db.helloDoc.insertOne({msg:"test", i})
db.helloDoc.getShardDistribution()
EOF
```

---

## Проверка Redis и кэширования

Очистить кэш:
```bash
docker compose exec -T redis redis-cli FLUSHALL
```

Сделать два запроса к API:
```bash
curl -s -w "\nfirst:  %{time_total}s\n"  -o /dev/null http://localhost:8080/hello-count
curl -s -w "\nsecond: %{time_total}s\n" -o /dev/null http://localhost:8080/hello-count
```

Во втором запросе ответ должен быть быстрее, а в Redis-мониторе появятся `SET` и `GET`.

---

## Полезные команды

Остановить всё:
```bash
docker compose down
```

Удалить все данные и запустить заново:
```bash
docker compose down -v
./init.sh
```

Посмотреть логи приложения:
```bash
docker compose logs -f app
```

Посмотреть Swagger (если включён):
```
http://localhost:8080/docs
```

---

## Порты

| Сервис | Порт хоста | Назначение |
|--------|-------------|------------|
| app    | 8080        | HTTP API |
| mongos | 27017       | Точка входа MongoDB |
| redis  | 6379        | Кэш |
