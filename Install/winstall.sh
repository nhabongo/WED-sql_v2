#!/bin/bash

TEMPLATE='wed_worker_template'
DB=$1
WORKER=${DB}_worker
USER=$2
CONFIG=$3

if [[ $# < 3 ]]
then
	echo "$0 <database name> <wedflow user> <postgresql.conf file>"
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
echo -e "Generating new WED-flow"
echo -n "New password for user $USER :" 
read -s PASSX
echo -ne "\nNew password for user $USER :" 
read -s PASSY
echo ''

if [[ $PASSX != $PASSY ]]
then
    echo "Passwords don't match, aborting ..."
    exit 1 
fi

echo -e "Creating new WED-flow database ..."

sudo -u postgres psql -q -c "CREATE DATABASE $DB ;"
if [[ $? != 0 ]]
then
    exit 1
fi 

sudo -u postgres psql -q -c "CREATE ROLE $USER WITH LOGIN PASSWORD '$PASSX' ;"
if [[ $? != 0 ]]
then
    sudo -u postgres psql -q -c "DROP DATABASE $DB ;"
    exit 1
else
    sudo -u postgres psql -q -c "REVOKE ALL ON DATABASE $DB FROM public ;"
    sudo -u postgres psql -q -c "GRANT CONNECT ON DATABASE $DB TO $USER ;"
fi 

echo -e "Installing WED-flow on database $DB ..."

sudo -u postgres psql -q -d $DB -f WED-flow.sql 
if [[ $? != 0 ]]
then
    sudo -u postgres psql -q -c "DROP DATABASE $DB ;"
    sudo -u postgres psql -q -c "DROP ROLE $USER ;"
fi

echo -e "Setting WED-user permissions on database $DB ..."

echo -e "GRANT USAGE ON SCHEMA public TO $USER;
         GRANT SELECT ON job_pool to $USER;
         GRANT SELECT ON st_status to $USER;
         GRANT SELECT ON wed_trace to $USER;
         GRANT SELECT,INSERT,UPDATE ON wed_attr to $USER;
         GRANT SELECT,INSERT,UPDATE ON wed_trig to $USER;
         GRANT SELECT,INSERT,UPDATE ON wed_flow to $USER;
         GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public to $USER;
         REVOKE ALL ON FUNCTION trcheck() FROM public;
         REVOKE EXECUTE ON FUNCTION trcheck() FROM $USER;
         GRANT USAGE ON ALL SEQUENCES IN SCHEMA public to $USER;" > tmp_priv
sudo -u postgres psql -q -d $DB -f tmp_priv
rm tmp_priv

echo -e  "Generating new bg_worker ..."
rm -rf $WORKER > /dev/null 2>&1
cp -r $TEMPLATE $WORKER
cd $WORKER
rename wed_worker $WORKER *
sed -i "s/wed_worker/$WORKER/g" *
sed -i "s/__DB_NAME__/\"$DB\"/" $WORKER.c
make > /dev/null

echo -e "Installing bg_worker ...\n"
make install
cd ../
echo ""
python pg_worker_register.py $WORKER $CONFIG 
if [[ $? != 0 ]]
then
	sudo -u postgres psql -q -d $DB -c "DROP OWNED BY $USER ;"
	sudo -u postgres psql -q -d $DB -c "DROP DATABASE $DB ;"
	sudo -u postgres psql -q -d $DB -c "DROP ROLE $USER ;"
else
	echo -e "Restarting postgresql server ..."
	systemctl restart postgresql
	echo -e "Cleaning temporary files ..."
	rm -rf $WORKER
fi

echo "DONE !"
exit 0
