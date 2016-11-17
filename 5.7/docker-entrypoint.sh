#!/bin/bash
set -eo pipefail
shopt -s nullglob

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
	case "$arg" in
		-'?'|--help|--print-defaults|-V|--version)
			wantHelp=1
			break
			;;
	esac
done

_check_config() {
	toRun=( "$@" --verbose --help )
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		cat >&2 <<-EOM

			ERROR: mysqld failed while attempting to check config
			command was: "${toRun[*]}"

			$errors
		EOM
		exit 1
	fi
}

_datadir() {
	"$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }'
}

# allow the container to be started with `--user`
if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -u)" = '0' ]; then
	_check_config "$@"
	DATADIR="$(_datadir "$@")"
	mkdir -p "$DATADIR"
	chown -R mysql:mysql /etc/mysql
	chown -R mysql:mysql "$DATADIR"
	exec gosu mysql "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
	# still need to check config, container may have started with --user
	_check_config "$@"
	# Get config
	DATADIR="$(_datadir "$@")"

	if [ ! -d "$DATADIR/mysql" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '	You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
			exit 1
		fi

		mkdir -p "$DATADIR"

		echo 'Initializing database'
		"$@" --initialize-insecure
		echo 'Database initialized'

		"$@" --skip-networking &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot -hlocalhost)

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
			# sed is for https://bugs.mysql.com/bug.php?id=20545
			mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		fi

		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi
		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--	or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;

			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)		 echo "$0: running $f"; . "$f" ;;
				*.sql)		echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
				*)				echo "$0: ignoring $f" ;;
			esac
			echo
		done

		if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				ALTER USER 'root'@'%' PASSWORD EXPIRE;
			EOSQL
		fi

		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi

	#
	# MySQL peer selection
	#
	# A value of:
	# MYSQL_REP_PEERS = "10.1.1.2:18267:1,10.1.1.3:29167:1,10.0.1.2:19345:3"
	#
	# will lead to the following circular replication
	# 10.1.1.2:18267 -> 10.1.1.3:29167 -> 10.0.1.2:19345 -> 10.1.1.2:18267 -> ...
	#
	if [ -n "$MYSQL_REP_PEERS" ]; then
		# Transform comma separated list of peers into an array
		arr_peers=(${MYSQL_REP_PEERS//,/ })
		self_index=
		master_index=
		slave_index=

		for i in "${!arr_peers[@]}"; do
			epeer=${arr_peers[$i]}
			peer=(${epeer//:/ })

			if [ "${peer[0]}:${peer[1]}" == "$SELF_HOST:$SELF_PORT" ]; then
				self_index=$i
				break
			fi
		done

		if [ -n "$self_index" ]; then
			let "master_index = ($self_index - 1) % ${#arr_peers[@]}" || true # avoid exiting when result is 1 due to set -e
			let "slave_index = ($self_index + 1) % ${#arr_peers[@]}" || true # avoid exiting when result is 1 due to set -e
		fi

		if [ -n "$self_index" ]; then
			epeer=${arr_peers[$self_index]}
			peer=(${epeer//:/ })
			MYSQL_SERVER_ID=${peer[2]}
			echo "Replication configuration for self: HOST=${SELF_HOST}, PORT=${SELF_PORT}, SERVER_ID=${MYSQL_SERVER_ID}"
		fi

		if [ -n "$master_index" ] && [ "$self_index" != "$master_index" ]; then
			epeer=${arr_peers[$master_index]}
			peer=(${epeer//:/ })
			MASTER_HOST=${peer[0]}
			MASTER_PORT=${peer[1]}
			echo "Replication configuration for master: HOST=${MASTER_HOST}, PORT=${MASTER_PORT}, SERVER_ID=${peer[2]}"
		fi

		if [ -n "$slave_index" ] && [ "$self_index" != "$slave_index" ]; then
			epeer=${arr_peers[$slave_index]}
			peer=(${epeer//:/ })
			SLAVE_HOST=${peer[0]}
			SLAVE_PORT=${peer[1]}
			echo "Replication configuration for slave: HOST=${SLAVE_HOST}, PORT=${SLAVE_PORT}, SERVER_ID=${peer[2]}"
		fi
	fi

	# Configure replication
	if [ -n "$MYSQL_SERVER_ID" ] && [ -n "$MYSQL_DATABASE" ]; then
		# Configure cluster
		cat <<-EOF > /etc/mysql/mysql.conf.d/cluster.cnf
		[mysqld]
		server-id							 = ${MYSQL_SERVER_ID}
		log_bin								 = /var/log/mysql/mysql-bin.log
		binlog_do_db						= ${MYSQL_DATABASE}
		relay_log							 = relay-log
		relay_log_index				= relay-bin.index
		log_slave_updates     = true
		EOF

		# Start mysql
		"$@" --skip-networking --skip-slave-start &
		pid="$!"

		# Helpers
		function execsql() {
			mysql -u root -p$MYSQL_ROOT_PASSWORD -e "$1"
		}
		function slave_execsql() {
			mysql -P $SLAVE_PORT -h $SLAVE_HOST -u root -p$MYSQL_ROOT_PASSWORD -e "$1"
		}

		for i in {30..0}; do
			if mysql -u root -p$MYSQL_ROOT_PASSWORD -e 'SELECT 1' &> /dev/null; then
				break
			fi
			echo 'MySQL startup process in progress...'
			sleep 1
		done

		if [ "$i" = 0 ]; then
			echo >&2 'MySQL startup process failed.'
			exit 1
		fi

		# Ensure replication user exists
		execsql "create user 'replicator'@'%' identified by '$MYSQL_ROOT_PASSWORD';" || echo "replicator user already exists"
		execsql "grant replication slave on *.* to 'replicator'@'%';"

		# Wait for master to be up
		if [ -n "$MASTER_HOST" ] && [ -n "$MASTER_PORT" ]; then
			for i in {5..0}; do
				if mysql -P $MASTER_PORT -h $MASTER_HOST -u root -p$MYSQL_ROOT_PASSWORD -e 'SELECT 1' &> /dev/null; then
					MASTER_UP=true
					break
				fi
				echo "Master not yet available ($MASTER_HOST:$MASTER_PORT). Waiting..."
				sleep 1
			done
		fi

		if [ -n "$MASTER_HOST" ] && [ -n "$MASTER_PORT" ] && [ "$MASTER_UP" == "true" ]; then
			# Create snapshots from self and master
			bkup_date=$(date +"%Y-%m-%d-%H-%M-%S")
			snapshots_dir=$DATADIR/snapshots
			mkdir -p $snapshots_dir

			echo "Create local snapshot: $snapshots_dir/$bkup_date.self.dump"
			mysqldump -u root -p$MYSQL_ROOT_PASSWORD --databases $MYSQL_DATABASE > $snapshots_dir/$bkup_date.self.dump

			echo "Create master snapshot: $snapshots_dir/$bkup_date.master.dump"
			mysqldump --master-data -P $MASTER_PORT -h $MASTER_HOST -u root -p$MYSQL_ROOT_PASSWORD --databases $MYSQL_DATABASE > $snapshots_dir/$bkup_date.master.dump

			# Configure replication for self and perform initial import
			echo "Stop slave and update master configuration on local instance"
			execsql "STOP SLAVE;"
			execsql "CHANGE MASTER TO MASTER_HOST = '$MASTER_HOST', MASTER_PORT = $MASTER_PORT, MASTER_USER = 'replicator', MASTER_PASSWORD = '$MYSQL_ROOT_PASSWORD';"

			echo "Import dump from master and restart local slave thread"
			mysql -u root -p$MYSQL_ROOT_PASSWORD < $snapshots_dir/$bkup_date.master.dump
			execsql "START SLAVE;"
		fi

		# Wait for slave to be up
		if [ -n "$SLAVE_HOST" ] && [ -n "$SLAVE_PORT" ] && [ -n "$SELF_HOST" ] && [ -n "$SELF_PORT" ]; then
			for i in {5..0}; do
				if mysql -P $SLAVE_PORT -h $SLAVE_HOST -u root -p$MYSQL_ROOT_PASSWORD -e 'SELECT 1' &> /dev/null; then
					SLAVE_UP=true
					break
				fi
				echo "Slave not yet available ($SLAVE_HOST:$SLAVE_PORT). Waiting..."
				sleep 1
			done
		fi

		if [ -n "$SLAVE_HOST" ] && [ -n "$SLAVE_PORT" ] && [ -n "$SELF_HOST" ] && [ -n "$SELF_PORT" ] && [ "$SLAVE_UP" == "true" ]; then
			# Configure replication for remote slave
			echo "Stop slave thread on remote slave"
			slave_execsql "STOP SLAVE;"

			echo "Update Master configuration on remote slave and restart slave thread"
			read CURRENT_LOG CURRENT_POS REP_DO_DBS < <(mysql -u root -p$MYSQL_ROOT_PASSWORD -BNe "SHOW MASTER STATUS;")
			slave_execsql "CHANGE MASTER TO MASTER_HOST = '$SELF_HOST', MASTER_PORT = $SELF_PORT, MASTER_USER = 'replicator', MASTER_PASSWORD = '$MYSQL_ROOT_PASSWORD', MASTER_LOG_FILE = '$CURRENT_LOG', MASTER_LOG_POS = $CURRENT_POS;"
			slave_execsql "START SLAVE;"
		fi

		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL replication process failed.'
			exit 1
		fi

		echo
		echo 'MySQL replication setup done. Ready for start up.'
		echo
	fi
fi

exec "$@"
