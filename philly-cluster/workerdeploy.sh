#!/bin/bash

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

echo "Script arguments: $*"

if [ $# != 3 ]; then
    echo "Usage: $0 <Load_Balancer_IP> <AdminUserName> <WorkerSKU>"
    exit 1
fi

NAME=$(hostname)
IP=$(ifconfig eth0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')

LOAD_BALANCER_IP=$1
ADMIN_USERNAME=$2
WORKERNODE_SKU=$3
PHILLY_HOME=/var/lib/philly

source ./common.sh

function updateStateMachineStatus()
{
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" mkdir /stateMachine/$NAME
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" set /stateMachine/$NAME/currentState "UP/ok"
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" set /stateMachine/$NAME/goalState UP
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" mkdir /resources/gpu/$IP
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" mkdir /resources/port/$IP
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" mkdir /resources/portRangeStart/$IP
}

function enableRDMA()
{
    WORKERNODE_SKU=${WORKERNODE_SKU,,} #switch to lowercase
    WORKERNODE_SKU=${WORKERNODE_SKU//_/-} #change dash into underscore

    if [[ "$WORKERNODE_SKU" == "standard-nc24rs-v2" ]];
    then
        {
            echo "#Enable RDMA"
            echo "OS.EnableRDMA=y"
            echo "OS.UpdateRdmaDriver=y"
        } >> /etc/waagent.conf
    fi
}

initialSetup $ADMIN_USERNAME $PHILLY_HOME
formatDatadisks
applyCloudConfig $LOAD_BALANCER_IP

sleep 20
updateStateMachineStatus
enableRDMA
