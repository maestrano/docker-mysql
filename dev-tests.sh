#!/bin/bash

# Container setup
HOST_PUB_IP=`ifconfig | grep en0 -A 5 | grep "inet " | cut -d' ' -f2`
PORT_NODE_1=33001
PORT_NODE_2=33002

docker run -d -p $PORT_NODE_1:3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_db \
  -e SELF_HOST=$HOST_PUB_IP \
  -e SELF_PORT=$PORT_NODE_1 \
  -e PEER_HOST=$HOST_PUB_IP \
  -e PEER_PORT=$PORT_NODE_2 \
  --name m1 \
  mysql:5.7

docker run -d -p $PORT_NODE_2:3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_db \
  -e SELF_HOST=$HOST_PUB_IP \
  -e SELF_PORT=$PORT_NODE_2 \
  -e PEER_HOST=$HOST_PUB_IP \
  -e PEER_PORT=$PORT_NODE_1 \
  --name m2 \
  mysql:5.7

# Replication config - server 1
docker exec -it m1 /bin/bash
cd /etc/mysql/mysql.conf.d
cat <<'EOF' > cluster.cnf
[mysqld]
server-id               = 1
log_bin                 = /var/log/mysql/mysql-bin.log
binlog_do_db            = app_db
EOF
exit


# Replication config - server 2
docker exec -it m2 /bin/bash
cd /etc/mysql/mysql.conf.d
cat <<'EOF' > cluster.cnf
[mysqld]
server-id               = 2
log_bin                 = /var/log/mysql/mysql-bin.log
binlog_do_db            = app_db
EOF
exit

# Restart
docker restart m1 m2

# On both replication setup
docker exec -it m1 /bin/bash
docker exec -it m2 /bin/bash

mysql -p$MYSQL_ROOT_PASSWORD -e "create user 'replicator'@'%' identified by 'password';"
mysql -p$MYSQL_ROOT_PASSWORD -e "grant replication slave on *.* to 'replicator'@'%';"

if [ -n "$PEER_HOST" ] && [ -n "$PEER_PORT" ]; then
  # Create snapshots from self and peer
  bkup_date=$(date +"%Y-%m-%d-%H-%M-%S")
  snapshots_dir=/var/lib/mysql/snapshots
  mkdir -p $snapshots_dir
  mysqldump -p$MYSQL_ROOT_PASSWORD --databases app_db > $snapshots_dir/$bkup_date.self.dump
  mysqldump -P $PEER_PORT -h $PEER_HOST -u root -p$MYSQL_ROOT_PASSWORD --databases app_db > $snapshots_dir/$bkup_date.peer.dump
  mysql -p$MYSQL_ROOT_PASSWORD < $snapshots_dir/$bkup_date.peer.dump

  # Configure replication for self
  read CURRENT_LOG CURRENT_POS REP_DO_DBS < <(mysql -P $PEER_PORT -h $PEER_HOST -u root -p$MYSQL_ROOT_PASSWORD -BNe "SHOW MASTER STATUS;")
  mysql -p$MYSQL_ROOT_PASSWORD -e "STOP SLAVE;"
  mysql -p$MYSQL_ROOT_PASSWORD -e "CHANGE MASTER TO MASTER_HOST = '$PEER_HOST', MASTER_PORT = $PEER_PORT, MASTER_USER = 'replicator', MASTER_PASSWORD = 'password', MASTER_LOG_FILE = '$CURRENT_LOG', MASTER_LOG_POS = $CURRENT_POS;"
  mysql -p$MYSQL_ROOT_PASSWORD -e "START SLAVE;"
  mysql -p$MYSQL_ROOT_PASSWORD -e "SHOW MASTER STATUS;"

  # Configure replication for peer remotely
  read CURRENT_LOG CURRENT_POS REP_DO_DBS < <(mysql -p$MYSQL_ROOT_PASSWORD -BNe "SHOW MASTER STATUS;")
  mysql -P $PEER_PORT -h $PEER_HOST -u root -p$MYSQL_ROOT_PASSWORD -e "STOP SLAVE;"
  mysql -P $PEER_PORT -h $PEER_HOST -u root -p$MYSQL_ROOT_PASSWORD -e "CHANGE MASTER TO MASTER_HOST = '$SELF_HOST', MASTER_PORT = $SELF_PORT, MASTER_USER = 'replicator', MASTER_PASSWORD = 'password', MASTER_LOG_FILE = '$CURRENT_LOG', MASTER_LOG_POS = $CURRENT_POS;"
  mysql -P $PEER_PORT -h $PEER_HOST -u root -p$MYSQL_ROOT_PASSWORD -e "START SLAVE;"
fi
exit

# Connect
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot

# Logs
docker logs -f m1
docker logs -f m2

# Status
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "SHOW MASTER STATUS;"
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "SHOW SLAVE STATUS;"
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "SHOW MASTER STATUS;"
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "SHOW SLAVE STATUS;"

# Testing
# read CURRENT_LOG CURRENT_POS < $(mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -BNe "SHOW MASTER STATUS;")
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "create table app_db.dummy (id varchar(10));"
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "show tables in app_db;"
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "show tables in app_db;"

# Replication testing
while true; do
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "insert into app_db.dummy VALUES(RAND(1000))"
done
while true; do
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "insert into app_db.dummy VALUES(RAND(1000))"
done

# Check status
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"

# Terminate
docker rm -f m1 m2
