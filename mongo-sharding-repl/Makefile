SHELL := /bin/bash
DC := docker compose
MONGOS := $(DC) exec -T mongos mongosh --host 127.0.0.1 --port 27017 --quiet

.PHONY: up reset status ping logs test down

up:
	./init.sh

reset:
	$(DC) down -v
	$(MAKE) up

down:
	$(DC) down -v

status:
	$(DC) exec -T config1  mongosh --port 27019 --quiet --eval 'print("cfgRS:", rs.status().myState)'
	$(DC) exec -T shard1-1 mongosh --port 27018 --quiet --eval 'print("s1-1:", rs.status().myState)'
	$(DC) exec -T shard1-2 mongosh --port 27018 --quiet --eval 'print("s1-2:", rs.status().myState)'
	$(DC) exec -T shard1-3 mongosh --port 27018 --quiet --eval 'print("s1-3:", rs.status().myState)'
	$(DC) exec -T shard2-1 mongosh --port 27018 --quiet --eval 'print("s2-1:", rs.status().myState)'
	$(DC) exec -T shard2-2 mongosh --port 27018 --quiet --eval 'print("s2-2:", rs.status().myState)'
	$(DC) exec -T shard2-3 mongosh --port 27018 --quiet --eval 'print("s2-3:", rs.status().myState)'

ping:
	$(DC) exec -T mongos bash -lc 'mongosh --quiet --eval "db.adminCommand(\"ping\").ok"'

test:
	$(DC) exec -T mongos bash -lc 'mongosh --quiet --host 127.0.0.1 --port 27017 --eval "const d=db.getSiblingDB(\"somedb\"); d.helloDoc.deleteMany({}); for(let i=0;i<20000;i++){d.helloDoc.insertOne({_id:i,msg:\"hi-\"+i})}; print(\"Всего:\", d.helloDoc.countDocuments());"'
	$(DC) exec -T mongos bash -lc 'mongosh --quiet --host 127.0.0.1 --port 27017 --eval "const d=db.getSiblingDB(\"somedb\"); d.helloDoc.getShardDistribution(); printjson(sh.status());"'
