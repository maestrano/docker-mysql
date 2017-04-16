# Maestrano MySQL
Docker image for MySQL with support for circular replication.

[![Build Status](https://travis-ci.org/maestrano/docker-mysql.svg?branch=master)](https://travis-ci.org/maestrano/docker-mysql)

## Example of circular replication
```sh
# Container setup
HOST_PUB_IP=`ifconfig | grep en0 -A 5 | grep "inet " | cut -d' ' -f2`
PORT_NODE_1=33001
PORT_NODE_2=33002
PORT_NODE_3=33004

docker run -d -p $PORT_NODE_1:3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_db \
  -e SELF_HOST=$HOST_PUB_IP \
  -e SELF_PORT=$PORT_NODE_1 \
  -e MYSQL_REP_PEERS=$HOST_PUB_IP:$PORT_NODE_1:1 \
  --name m1 \
  maestrano/mysql:5.7

docker run -d -p $PORT_NODE_2:3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_db \
  -e SELF_HOST=$HOST_PUB_IP \
  -e SELF_PORT=$PORT_NODE_2 \
  -e MYSQL_REP_PEERS=$HOST_PUB_IP:$PORT_NODE_1:1,$HOST_PUB_IP:$PORT_NODE_2:2 \
  --name m2 \
  maestrano/mysql:5.7

docker run -d -p $PORT_NODE_3:3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_db \
  -e SELF_HOST=$HOST_PUB_IP \
  -e SELF_PORT=$PORT_NODE_3 \
  -e MYSQL_REP_PEERS=$HOST_PUB_IP:$PORT_NODE_1:1,$HOST_PUB_IP:$PORT_NODE_2:2,$HOST_PUB_IP:$PORT_NODE_3:3 \
  --name m3 \
  maestrano/mysql:5.7

# Testing
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
while true; do
mysql -P $PORT_NODE_3 -h $HOST_PUB_IP -u root -proot -e "insert into app_db.dummy VALUES(RAND(1000))"
done

# Check status
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"
mysql -P $PORT_NODE_3 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"

# Terminate
docker rm -f m1 m2 m3
```

## Example of master-slave configuration
```sh
HOST_PUB_IP=`ifconfig | grep en0 -A 5 | grep "inet " | cut -d' ' -f2`
PORT_NODE_1=33001
PORT_NODE_2=33002
PORT_NODE_3=33004

docker run -d -p $PORT_NODE_1:3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_db \
  -e SELF_HOST=$HOST_PUB_IP \
  -e SELF_PORT=$PORT_NODE_1 \
  -e MYSQL_SERVER_ID=1 \
  --name m1 \
  maestrano/mysql:5.7

docker run -d -p $PORT_NODE_2:3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_db \
  -e SELF_HOST=$HOST_PUB_IP \
  -e SELF_PORT=$PORT_NODE_2 \
  -e MYSQL_SERVER_ID=2 \
  -e MASTER_HOST=$HOST_PUB_IP \
  -e MASTER_PORT=$PORT_NODE_1 \
  --name m2 \
  maestrano/mysql:5.7

docker run -d -p $PORT_NODE_3:3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=app_db \
  -e SELF_HOST=$HOST_PUB_IP \
  -e SELF_PORT=$PORT_NODE_3 \
  -e MYSQL_SERVER_ID=3 \
  -e MASTER_HOST=$HOST_PUB_IP \
  -e MASTER_PORT=$PORT_NODE_1 \
  --name m3 \
  maestrano/mysql:5.7

# Testing
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "create table app_db.dummy (id varchar(10));"
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "show tables in app_db;"
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "show tables in app_db;"

# Replication testing
while true; do
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "insert into app_db.dummy VALUES(RAND(1000))"
done

# Check status
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"
mysql -P $PORT_NODE_3 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"

# Terminate
docker rm -f m1 m2 m3
```
