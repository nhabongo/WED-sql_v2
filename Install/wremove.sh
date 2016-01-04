#!/bin/bash

TEMPLATE='wed_worker_template'
DB=$1
WORKER=${DB}_worker
CONFIG=$3
USER=$2

if [[ $# < 3 ]]
then
	echo "$0 <database name> <user name> <postgresql.conf file>"
	exit 1
elif [[ $UID != 0 ]]
then
	echo "Need to be root!"
	exit 1
elif [[ ! -f $3 ]]
then
	echo "File $3 not found"
	exit 1
fi

echo -e "Removing bg_worker ...\n"
python pg_worker_unregister.py $WORKER $CONFIG 
if [[ $? == 0 ]]
then
	rm -f '/usr/share/postgresql/extension'/${WORKER}.control
    rm -f '/usr/share/postgresql/extension'/${WORKER}--1.0.sql
    rm -f '/usr/lib/postgresql'/${WORKER}.so

	echo -e "Restarting postgresql server ..."
	systemctl restart postgresql
	echo -e "Removing database $DB ..."
	echo -e "DROP OWNED BY $USER ;
	         DROP DATABASE $DB ;
	         DROP ROLE $USER ;" > tmp_drop
	sudo -u postgres psql -f tmp_drop
	rm -f tmp_drop
fi

echo "DONE !"
exit 0
