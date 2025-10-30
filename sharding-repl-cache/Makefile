SHELL := /bin/bash
DC := docker compose
MONGOS := $(DC) exec -T mongos mongosh --port 27017 --quiet

.PHONY: up reset status ping logs test down clean ps

up:
	@echo "Запускаю весь кластер Mongo + Redis + App..."
	./init.sh

reset:
	@echo "Полный сброс кластеров и данных..."
	$(DC) down -v
	$(MAKE) up

down:
	@echo "Останавливаю контейнеры..."
	$(DC) down -v

logs:
	$(DC) logs -f

ps:
	$(DC) ps

status:
	@echo "cfgReplSet:"
	$(DC) exec -T configsvr01 mongosh --port 27019 --quiet --eval 'printjson(rs.status().members.map(m=>({name:m.name,state:m.stateStr})))'
	@echo "shard01:"
	$(DC) exec -T shard01a mongosh --port 27018 --quiet --eval 'printjson(rs.status().members.map(m=>({name:m.name,state:m.stateStr})))'
	@echo "shard02:"
	$(DC) exec -T shard02a mongosh --port 27018 --quiet --eval 'printjson(rs.status().members.map(m=>({name:m.name,state:m.stateStr})))'

ping:
	$(MONGOS) --eval 'db.adminCommand({ping:1})'

test:
	@echo "Включаем шардирование для базы somedb..."
	$(MONGOS) --eval 'sh.enableSharding("somedb")'
	$(MONGOS) --eval 'sh.shardCollection("somedb.helloDoc", { _id: "hashed" })'

	@echo "Вставляем тестовые документы..."
	$(MONGOS) --eval 'const d=db.getSiblingDB("somedb"); d.helloDoc.deleteMany({}); for(let i=0;i<20000;i++){d.helloDoc.insertOne({_id:i,msg:"hi-"+i})}; print("Всего:", d.helloDoc.countDocuments());'

	@echo "Проверяем распределение по шардам..."
	$(MONGOS) --eval 'const d=db.getSiblingDB("somedb"); d.helloDoc.getShardDistribution(); printjson(sh.status().shards);'

clean:
	$(DC) down -v
