# docker-mysql

**Example on local machine:**
```sh
# Container setup
HOST_PUB_IP=`ifconfig | grep en0 -A 5 | grep "inet " | cut -d' ' -f2`
PORT_NODE_1=33001
PORT_NODE_2=33002

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
  -e PEER_HOST=$HOST_PUB_IP \
  -e PEER_PORT=$PORT_NODE_1 \
  -e MASTER_MASTER_REP=true \
  -e MYSQL_SERVER_ID=2 \
  --name m2 \
  alachaum/mysql:5.7

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

# Check status
mysql -P $PORT_NODE_1 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"
mysql -P $PORT_NODE_2 -h $HOST_PUB_IP -u root -proot -e "SELECT COUNT(*) FROM app_db.dummy"

# Terminate
docker rm -f m1 m2
```
