 #!/bin/bash
export ANSIBLE_HOST_KEY_CHECKING=False

INSTANCES_LIST=()
CLUSTER_IP_MEMBERS=""
COUNTER=1
while [ $COUNTER -le $MYSQL_COUNT ]; do
	INSTNAME=$CLUSTER_PREFIX
	
	if [ $COUNTER == 1 ]; then
		INSTNAME+="-Bootstrapper-MySql"
	else
		INSTNAME+="-MySql_"
		INSTNAME+=$COUNTER
	fi
	
	echo Creating $INSTNAME instance

	nova boot --flavor "$FSMALL" --image "$IMAGE_ID" --key_name "$CLUSTER_PREFIX" --security_groups "$MYSQL_SECURITY_GROUP" $INSTNAME --poll --user-data hosts.sh --nic net-id=$NETID

	sleep 15 # delay for nw_info cache renew. see https://bugs.launchpad.net/nova/+bug/1249065
	
	nova floating-ip-create |grep $EXTNETNAME | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' > pub_ip/$INSTNAME
	nova list|grep $INSTNAME|grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'|grep '10.0.0' > local_ip/$INSTNAME
	read -r INSTIP < pub_ip/$INSTNAME
	
	# associate public IP with the instance
	nova floating-ip-associate $INSTNAME $INSTIP
	
	INSTANCES_LIST+=("$INSTNAME:$INSTIP")
	
	if [ $COUNTER == 1 ]; then
		CLUSTER_IP_MEMBERS+=$INSTIP
	else
		CLUSTER_IP_MEMBERS+=","
		CLUSTER_IP_MEMBERS+=$INSTIP
	fi
	
	let COUNTER=COUNTER+1 
done

sleep 60

# Create HA Proxy
HA_PROXY_NAME=$CLUSTER_PREFIX
HA_PROXY_NAME+="-Proxy_Db"
source ./create_inst.sh 4 $HA_PROXY_NAME

MASTER_NOT_CREATED="True"
for instance in "${INSTANCES_LIST[@]}" ; do
# Install MySql servers
    SERVER_NAME=${instance%%:*}
    SERVER_IP=${instance#*:}

	ansible-playbook ansible/galera.yml -i pub_ip/$SERVER_NAME --private-key=keys/$CLUSTER_PREFIX.pem -u ubuntu -v -e "galera_cluster_members=$CLUSTER_IP_MEMBERS" -e "galera_node_ip=$SERVER_IP" -e "galera_master=$MASTER_NOT_CREATED"
	
	if [ $MASTER_NOT_CREATED == "False" ]; then
		source ./haproxy_clients_add.sh $HA_PROXY_NAME $SERVER_NAME
	fi
	
	MASTER_NOT_CREATED="False"
done

# Initialize MySql database
# Need to initialize only one instance
# Data will be shared between instances automatically
ansible-playbook ansible/createdb.yml -i pub_ip/${INSTANCES_LIST[1]%%:*} --private-key=keys/$CLUSTER_PREFIX.pem -u ubuntu -v