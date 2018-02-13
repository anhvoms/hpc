#!/bin/bash

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

echo "Script arguments: $*"

if [ $# != 20 ]; then
    echo "Usage: $0 <LoadBalancerIP> <AdminUserName> <InfraBaseName> <InfraCount> <IpBase> <IpStart> <WorkerBaseName> <WorkerCount> <WorkerIpBase> <WorkerIpStart> <GfsBaseName> <GfsCount> <GfsIpBase> <GfsIpStart> <InfraSKU> <WorkerSKU> <GfsSKU> <ClusterYmlUrl> <CloudConfigTemplate> <ClusterId>"
    exit 1
fi

NAME=$(hostname)

isWorker=0
if [[ $NAME == *"worker"* ]]; then isWorker=1; fi

isInfra=0
if [[ $NAME == *"infra"* ]]; then isInfra=1; fi

LOAD_BALANCER_IP=$1
ADMIN_USERNAME=$2

INFRA_BASE_NAME=$3
INFRA_COUNT=$4
INFRA_IP_BASE=$5
INFRA_IP_START=$6

WORKER_BASE_NAME=$7
WORKER_COUNT=$8
WORKER_IP_BASE=$9
WORKER_IP_START=${10}

GFS_BASE_NAME=${11}
GFS_COUNT=${12}
GFS_IP_BASE=${13}
GFS_IP_START=${14}

HEADNODE_SKU=${15}
WORKERNODE_SKU=${16}
GFSNODE_SKU=${17}
CLUSTERYML=${18}
CLOUDCONFIG=${19}
CLUSTER=${20}

PHILLY_HOME=/var/lib/philly
masterIndex=0

function startService()
{
    fleetctl start $PHILLY_HOME/services/$1.service
    sleep 10
}


function startServiceWaitForRunning()
{
    startService $1
    while [[ -n $(fleetctl list-units --fields unit,sub | grep $1 | grep -E 'dead|start-pre|auto-restart') ]];
    do
        sleep 5
    done
}


function startServiceWaitForExited()
{
    startService $1
    while [[ -n $(fleetctl list-units --fields unit,sub | grep $1 | grep -E 'dead|start-pre|auto-restart|running') ]];
    do
        sleep 5
    done
}


function fixHostsFile()
{
    echo "Fixing up hosts file to include entries to other infrastructure nodes and worker nodes"

    if [[ $isInfra -eq 1 ]];
    then
        localhostLine=$(grep 127.0.0.1 /etc/hosts)
        if [[ -z $localhostLine ]];
        then
            echo "127.0.0.1 localhost infra" >> /etc/hosts
        else
            sed -i "s/$localhostLine/$localhostLine infra/g" /etc/hosts
        fi
        echo $INFRA_IP_BASE$INFRA_IP_START master >> /etc/hosts
    fi


    i=0
    while [ $i -lt $INFRA_COUNT ]
    do
        nextip=$((i + INFRA_IP_START))
        echo $INFRA_IP_BASE$nextip $INFRA_BASE_NAME$i >> /etc/hosts
        ((++i))
    done

    echo "Finished setting up hosts file"
}


function generateMachinesYml()
{
    echo "Generating machines.yml file to be included as part of cluster.yml"

    machineYmlFile="$PHILLY_HOME/machines.yml"
    echo "#This file is generated automatically at provisioning" > $machineYmlFile

    #need to convert the Azure sku string to what philly likes
    HEADNODE_SKU=${HEADNODE_SKU,,} #switch to lowercase
    HEADNODE_SKU=${HEADNODE_SKU//_/-} #change dash into underscore
    WORKERNODE_SKU=${WORKERNODE_SKU,,} #switch to lowercase
    WORKERNODE_SKU=${WORKERNODE_SKU//_/-} #change dash into underscore
    GFSNODE_SKU=${GFSNODE_SKU,,} #switch to lowercase
    GFSNODE_SKU=${GFSNODE_SKU//_/-} #change dash into underscore

    {
    i=0
    while [ $i -lt $INFRA_COUNT ]
    do
        nextip=$((i + INFRA_IP_START))
        echo "    $INFRA_BASE_NAME$i:"
        echo "      sku: $HEADNODE_SKU"
        echo "      rack: rack0"
        echo "      rackLocation: 1"
        echo "      outlet: 1.0"
        echo "      role: infrastructure"
        echo "      mac: 00:00:00:00:00:00"
        echo "      ip: $INFRA_IP_BASE$nextip"
        echo "      infraId: $i"
        if [ $i -lt 3 ]
        then
            echo "      yarnNodeId: $((i+1))"
        fi

        if [ $i -lt 2 ]
        then
            echo "      hdfsNameNodeId: $((i+1))"
        fi
        echo "      os: prod-infra"
        ((++i))
    done

    i=0
    while [ $i -lt $GFS_COUNT ]
    do
        nextip=$((i + WORKER_IP_START))
        j=$(seq -f "%03g" $i $i)
        echo "    $GFS_BASE_NAME$j:"
        echo "      sku: $GFS_SKU"
        echo "      rack: rack0"
        echo "      rackLocation: 1"
        echo "      outlet: 1.0"
        echo "      role: auxiliary.gfs"
        echo "      mac: 00:00:00:00:00:00"
        echo "      ip: $GFS_IP_BASE$nextip"
        echo "      os: prod-worker"
        ((++i))
    done

    i=0
    while [ $i -lt $WORKER_COUNT ]
    do
        nextip=$((i + WORKER_IP_START))
        j=$(seq -f "%04g" $i $i)
        echo "    $WORKER_BASE_NAME$j:"
        echo "      sku: $WORKERNODE_SKU"
        echo "      rack: rack1"
        echo "      rackLocation: 1"
        echo "      outlet: 1.0"
        echo "      role: worker"
        echo "      mac: 00:00:00:00:00:00"
        echo "      ip: $WORKER_IP_BASE$nextip"
        echo "      os: prod-worker"
        ((++i))
    done
    } >> $machineYmlFile

    echo "Finished setting up machines.yml file"
}


function updateConfigFile()
{
    echo "Updating cloud-config.yml file"

    cp $PHILLY_HOME/azure.yml $PHILLY_HOME/azure.yml.orig
    if [[ "$CLUSTERYML" == "none" ]] ; then
        echo "Using the image's cluster yml file $PHILLY_HOME/azure.yml"
        sed -i "s/__CLUSTER__/$CLUSTER/g" $PHILLY_HOME/azure.yml
    else
        wget $CLUSTERYML -O $PHILLY_HOME/azure.yml
        CLUSTER=$(grep -m 1 "id: " $PHILLY_HOME/azure.yml | awk -F" " '{print $2}')
    fi

    cp $PHILLY_HOME/cloud-config.yml $PHILLY_HOME/cloud-config.yml.orig
    if [[ "$CLOUDCONFIG" == "none" ]] ; then
        echo "Using the image's cloud config template $PHILLY_HOME/cloud-config.yml.template"
    else
        wget $CLOUDCONFIG -O $PHILLY_HOME/cloud-config.yml.template
    fi

    $PHILLY_HOME/tools/generate-config -c $PHILLY_HOME/azure.yml --host $NAME -t $PHILLY_HOME/cloud-config.yml.template > $PHILLY_HOME/cloud-config.yml

    echo "Finished updating cloud-config.yml file"
}


function updateResolvConf()
{
    #worker setup is not started until infra nodes are finished setting up
    #by that time dns from infra nodes are already up
    if [[ $isInfra -eq 1 ]];
    then
        while [[ -z $(netstat -nlp 2>/dev/null | grep 127.0.0.1:53) ]];
        do
            sleep 5
        done

        #Wait for all infrastructure nodes to come up
        #if upinfra is not up webserver will start ok but not answering http request
        i=0
        while [ $i -lt $INFRA_COUNT ]
        do
            nextip=$((i + INFRA_IP_START))
            dnsServer=$INFRA_IP_BASE$nextip
            until nslookup upinfra.$CLUSTER.philly.selfhost.corp.microsoft.com $dnsServer; do sleep 5; done;
            ((++i))
        done
 
        #Rewrite /etc/resolv.conf after dns is up
        azureInternalDomain=$(grep search /etc/resolv.conf | awk -F' ' '{print $2}')
        cp /var/lib/philly/newresolv.conf /etc/resolv.conf
        sed -i "s/search $CLUSTER.philly.selfhost.corp.microsoft.com/search $CLUSTER.philly.selfhost.corp.microsoft.com $azureInternalDomain/g" /etc/resolv.conf
    fi

    #at this point dns is up, so we remove the infra and master entry from hosts file
    sed -i "s/127.0.0.1 localhost infra/127.0.0.1 localhost/g" /etc/hosts
    sed -i "s/$INFRA_IP_BASE$INFRA_IP_START master//g" /etc/hosts
}


function applyCloudConfigInfra()
{
    [[ ! -d /var/lib/coreos-install ]] && mkdir -p /var/lib/coreos-install

    if [[ $isInfra -eq 1 ]];
    then
        #Backup our /etc/resolv.conf because cloud-config will overwrite it and
        #we can't use that one yet
        cp /etc/resolv.conf /var/lib/philly/resolv.conf
    fi

    coreos-cloudinit --from-file $PHILLY_HOME/cloud-config.yml
    if [[ -z $(id -u core 2>&1 | grep "no such user") ]]; then
        echo "core ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
        usermod -a -G systemd-journal core
    fi

    if [[ $isInfra -eq 1 ]];
    then
           #Save the newly generated /etc/resolv.conf
           cp /etc/resolv.conf /var/lib/philly/newresolv.conf
           cp /var/lib/philly/resolv.conf /etc/resolv.conf
    fi

    #Wait for fleet to be ready
    while [[ $(fleetctl list-machines | wc -l) -lt $INFRA_COUNT ]]; do sleep 5; done
    cp $PHILLY_HOME/cloud-config.yml /var/lib/coreos-install/user_data

    sed -i "s/exit 0//g" /etc/rc.local
    {
        echo "LOAD_BALANCER_IP=$LOAD_BALANCER_IP"
        echo '[ ! -f "/var/lib/coreos-install/user_data" ] &&'
        echo '    sudo curl "http://$LOAD_BALANCER_IP/cloud-config/$(hostname).yml?reconfigure" -o /var/lib/coreos-install/user_data'
        echo '[ -f "/var/lib/coreos-install/user_data" ] &&'
        echo '    coreos-cloudinit --from-file=/var/lib/coreos-install/user_data'
    } >> /etc/rc.local
}


function startCoreServices()
{
    if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then

        #Push cluster config to ETCD
        $PHILLY_HOME/tools/pcm -e localhost -c $PHILLY_HOME/azure.yml pushcfg

        #Add activeNameNode key for DNS module
        etcdctl set /activeNameNode $INFRA_BASE_NAME$masterIndex

        etcdctl mkdir /eventqueue

        for service in docker-registry master dns
        do
            startServiceWaitForRunning $service
            sleep 30
        done
        updateResolvConf

        startServiceWaitForRunning webserver

    else
        updateResolvConf
    fi

    #restart docker service so we can start pulling from master's registry
    #/etc/init.d/docker restart
}


function startHadoopServices()
{
    if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then

        #zookeeper sometimes takes a while to finish leader election
        startServiceWaitForRunning zookeeper
        sleep 120

        for service in hadoop-journal-node hadoop-name-node hadoop-data-node hadoop-resource-manager
        do
            startServiceWaitForRunning $service
        done
    fi

    m=$(seq -f "%04g" $masterIndex $masterIndex)
    if [ "$NAME" == "$WORKER_BASE_NAME$m" ] ; then
        #
        # workers are part of hadoop data node set, first worker should create the hdfs directory that is needed
        # for alertserver
        #
        while [[ -n $(fleetctl list-units --fields unit,sub | grep hadoop-data-node | grep -E 'dead|start-pre|auto-restart') ]];
        do
            sleep 5
        done
        ret=$(/opt/bin/hdfs mkdir -p hdfs://hnn-1:8020/sys/runtimes 2>&1)
        if [[ -n "$ret" ]]; then
            ret=$(/opt/bin/hdfs mkdir -p hdfs://hnn-2:8020/sys/runtimes 2>&1)
        fi
    fi
}


function startOtherServices()
{
    if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then
        etcdctl mkdir stateMachine
        etcdctl mkdir resources/gpu
        etcdctl mkdir resources/port
        etcdctl mkdir resources/portRangeStart
        etcdctl mkdir viz/requests
        etcdctl mkdir viz/contracts
        etcdctl mkdir jobs/pnrsy

        i=0
        while [ $i -lt $INFRA_COUNT ]
        do
            nextip=$((i + INFRA_IP_START))
            etcdctl mkdir stateMachine/$INFRA_BASE_NAME$i
            etcdctl mk stateMachine/$INFRA_BASE_NAME$i/currentState "UP/ok"
            etcdctl mk stateMachine/$INFRA_BASE_NAME$i/goalState UP

            etcdctl mkdir resources/gpu/$INFRA_IP_BASE$nextip
            etcdctl mkdir resources/port/$INFRA_IP_BASE$nextip
            etcdctl mkdir resources/portRangeStart/$INFRA_IP_BASE$nextip
            ((++i))
        done

        i=0
        while [ $i -lt $GFS_COUNT ]
        do
            nextip=$((i + GFS_IP_START))
            etcdctl mkdir stateMachine/$GFS_BASE_NAME$i
            etcdctl mk stateMachine/$GFS_BASE_NAME$i/currentState UP
            etcdctl mk stateMachine/$GFS_BASE_NAME$i/goalState UP

            etcdctl mkdir resources/gpu/$GFS_IP_BASE$nextip
            etcdctl mkdir resources/port/$GFS_IP_BASE$nextip
            etcdctl mkdir resources/portRangeStart/$GFS_IP_BASE$nextip
            ((++i))
        done

        i=0
        while [ $i -lt $WORKER_COUNT ]
        do
            nextip=$((i + INFRA_IP_START))
            j=$(seq -f "%04g" $i $i)
            etcdctl mkdir stateMachine/$WORKER_BASE_NAME$j
            etcdctl mk stateMachine/$WORKER_BASE_NAME$j/currentState UP
            etcdctl mk stateMachine/$WORKER_BASE_NAME$j/goalState UP

            etcdctl mkdir resources/gpu/$WORKER_IP_BASE$nextip
            etcdctl mkdir resources/port/$WORKER_IP_BASE$nextip
            etcdctl mkdir resources/portRangeStart/$WORKER_IP_BASE$nextip
            ((++i))
        done
        startService ganglia-client
    fi
}

# Main script body
#
source ./common.sh

initialSetup $ADMIN_USERNAME $PHILLY_HOME
formatDatadisks
fixHostsFile

generateMachinesYml
updateConfigFile

applyCloudConfigInfra
startCoreServices

#startHadoopServices
#startOtherServices
exit 0
