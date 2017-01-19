#!/bin/bash
#
# This script creates a full backup of the mysql database
# and rolls backup files over
#
set -e

# Configuration
BKUP_DIR=${BKUP_DIR:-"/var/lib/mysql/backups"}
BKUP_RETENTION=${BKUP_RETENTION:-20}

# Ensure backup directory exists
mkdir -p $BKUP_DIR

# Perform backup
ts=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
mysqldump -u root -p$MYSQL_ROOT_PASSWORD --single-transaction --routines --triggers --all-databases > /dev/null 2>&1 | gzip > $BKUP_DIR/$ts.sql.gz

# Keep limited number of backups
ls -1 $BKUP_DIR/*.sql.gz | head -n -${BKUP_RETENTION} | xargs -d '\n' rm -f --
