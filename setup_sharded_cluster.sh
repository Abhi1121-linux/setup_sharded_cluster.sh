#!/bin/bash

#OWNER:ABHISHEK VISHWAKARMA

set -euo pipefail

# =================================================================
# MongoDB Sharded Cluster Setup (MongoDB 6.x)
# - 1 config server replica set (configReplSet)
# - 3 shard replica sets (shard1, shard2, shard3) each single-member
# - 1 mongos router
# =================================================================

#------------User-configurable ------------------------------------
IP="localhost"
BASE_PATH="${HOME}/mongodb_cluster"
CONFIG_PORT=27021
MONGOS_PORT=27017

# shard name => port

declare -A SHARDS
SHARDS=( ["shard1"]=27018 ["shard2"]=27019 ["shard3"]=27020 )
# ----------------------------------------------------------------

# check tools 
for TOOL in mongod mongos mongosh; do
	if ! command -v "${TOOL}" >/dev/null 2>&1; then
		echo "ERROR: ${TOOL} not found in PATH. Install MongoDB tools and retry." >&2
		exit 1
	fi
done

echo "📂 Creating directories under ${BASE_PATH}..."
rm -rf "${BASE_PATH}" || true
mkdir -p "${BASE_PATH}/config"
for SH in "${!SHARDS[@]}"; do
    mkdir -p "${BASE_PATH}/${SH}"
done

# ------------------------- start config server (replica set) -----------

echo "🔹 Starting config server (configReplSet) on ${IP}:${CONFIG_PORT}..."
mongod --configsvr --replSet configReplSet --port "${CONFIG_PORT}" \
      --dbpath "${BASE_PATH}/config" --bind_ip "${IP}" --fork \
      --logpath "${BASE_PATH}/config/mongod.log"


# Wait and initiate config replica set 

sleep 2
echo "🔸 Initiating config server replica set..."
mongosh --quiet --port "${CONFIG_PORT}" --eval "rs.initiate({_id:'configReplSet', configsvr:true, members:[{_id:0, host:'${IP}:${CONFIG_PORT}'}]});"

# Print config server status 
sleep 1
echo "📈 config server rs.status():"
mongosh --quiet --port "${CONFIG_PORT}" --eval "printjson(rs.status())"

# --------------------- Start Shard Replica Sets ---------------------------

for SH in "${!SHARDS[@]}";do
	PORT=${SHARDS[$SH]}
	echo "🔹 Starting shard ${SH} (replica set) on ${IP}:${PORT}..."
	mongod --shardsvr --replSet "${SH}" --port "${PORT}" \
		--dbpath "${BASE_PATH}/${SH}" --bind_ip "${IP}" --fork \
		--logpath "${BASE_PATH}/${SH}/mongod.log"
	sleep 2
	echo "🔸 Initiating replica set for ${SH}..."
	  mongosh --quiet --port "${PORT}" --eval "rs.initiate({_id:'${SH}', members:[{_id:0, host:'${IP}:${PORT}'}]});"
  sleep 1
  echo "📈 ${SH} rs.status():"
  mongosh --quiet --port "${PORT}" --eval "printjson(rs.status())"
done

# ------------------------- start mongos router ---------------------------
echo "🔹 Starting mongos router (configdb=configReplSet/${IP}:${CONFIG_PORT}) on port ${MONGOS_PORT}..."
mongos --configdb configReplSet/"${IP}:${CONFIG_PORT}" --port "${MONGOS_PORT}" --bind_ip "${IP}" --fork --logpath "${BASE_PATH}/mongos.log"


# wait for mongos to be ready 

sleep 3 

# ----------------------- Add shards to cluster via mongos ----------------

echo "🔸 Adding shards to cluster via mongos..."
for SH in "${!SHARDS[@]}"; do
	PORT=${SHARDS[$SH]}
	echo "   -> Adding ${SH} at ${IP}:${PORT}"

	# add as replica-set qualified shard name: shardName/host:port
	mongosh --quiet --port "${MONGOS_PORT}" --eval "sh.addShard('${SH}/${IP}:${PORT}');"
done

sleep 2


# ----------------- Final checks and output -----------------
echo "🎉 MongoDB Sharded Cluster setup complete!"
echo "➡ Connect to mongos: mongosh --port ${MONGOS_PORT}"
echo
echo "----- mongos sh.status() -----"
mongosh --quiet --port "${MONGOS_PORT}" --eval "sh.status();"

echo
echo "----- Tail last 20 lines of each mongod log -----"
for SH in "${!SHARDS[@]}"; do
	PORT=${SHARDS[$SH]}
	echo "---- ${SH} log (${BASE_PATH}/${SH}/mongod.log) ----"
	tail -n 20 "${BASE_PATH}/${SH}/mongod.log" || true
done

echo "--- ${SH} log (${BASE_PATH}/${SH}/mongod.log) ----"
tail -n 20 "${BASE_PATH}/config/mongod.log" || true
echo "--- mongos log (${BASE_PATH}/mongos.log) ----"
tail -n 20 "${BASE_PATH}/mongos.log" || true
