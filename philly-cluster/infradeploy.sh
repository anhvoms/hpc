#!/bin/bash

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

echo "Script arguments: $*"

if [ $# != 14 ]; then
    echo "Usage: $0 <InfraNodeCount> <AdminUserName> <AdminUserPassword> <InfraBaseName> <IpBase> <IpStart> <WorkerBaseName> <WorkerNodeCount> <WorkerIpBase> <WorkerIpStart> <TemplateBaseUrl> <HeadNodeSKU> <WorkerNodeSKU> <ClusterYml>"
    exit 1
fi

NAME=$(hostname)
IP=$(ifconfig eth0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')

isWorker=0
if [[ $NAME == *"worker"* ]]; then isWorker=1; fi

INFRA_COUNT=$1
ADMIN_USERNAME=$2
ADMIN_PASSWORD=$3
INFRA_BASE_NAME=$4
INFRA_IP_BASE=$5
INFRA_IP_START=$6

WORKER_BASE_NAME=$7
WORKER_COUNT=$8
WORKER_IP_BASE=$9
WORKER_IP_START=${10}
TEMPLATE_BASE=${11}
HEADNODE_SKU=${12}
WORKERNODE_SKU=${13}
CLUSTERYML=${14}

PHILLY_HOME=/var/lib/philly
masterIndex=0
cluster=azeast

function initialSetup()
{
    echo "Initial Setup: get new machine id, copy stored .ssh folder"
    
    # update machine-id because all VM's start from the same image.
    # fleet/etcd uses /etc/machine-id to self identify
    rm /etc/machine-id
    systemd-machine-id-setup
    
    # Don't require password for HPC user sudo
    echo "$ADMIN_USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers
    mkdir -p /home/$ADMIN_USERNAME/.ssh
    mkdir -p ~/.ssh
    cp $PHILLY_HOME/bootstrap/.ssh/* /home/$ADMIN_USERNAME/.ssh
    cp $PHILLY_HOME/bootstrap/.ssh/* ~/.ssh
    
    chmod 700 /home/$ADMIN_USERNAME/.ssh
    chmod 400 /home/$ADMIN_USERNAME/.ssh/config
    chmod 640 /home/$ADMIN_USERNAME/.ssh/authorized_keys
    chmod 400 /home/$ADMIN_USERNAME/.ssh/id_rsa
    chown -R $ADMIN_USERNAME:$ADMIN_USERNAME /home/$ADMIN_USERNAME/.ssh

    usermod -a -G systemd-journal $ADMIN_USERNAME
    usermod -a -G docker $ADMIN_USERNAME
    echo "Initial setup done"
}


function fixHostsFile()
{
    echo "Fixing up hosts file to include entries to other infrastructure nodes and worker nodes"

    if [[ $isWorker -eq 0 ]];
    then    
        localhostLine=$(grep 127.0.0.1 /etc/hosts)
        if [[ -z $localhostLine ]];
        then
            echo "127.0.0.1 localhost infra" >> /etc/hosts
        else
            sed -i "s/$localhostLine/$localhostLine infra/g" /etc/hosts
        fi
    fi
    
    echo $INFRA_IP_BASE$INFRA_IP_START master >> /etc/hosts

    i=0
    while [ $i -lt $INFRA_COUNT ]
    do
        nextip=$((i + INFRA_IP_START))
        echo $INFRA_IP_BASE$nextip $INFRA_BASE_NAME$i >> /etc/hosts
        ((++i))
    done

    i=0
    while [ $i -lt $WORKER_COUNT ]
    do
        nextip=$((i + WORKER_IP_START))
        echo $WORKER_IP_BASE$nextip $WORKER_BASE_NAME$i >> /etc/hosts
        ((++i))
    done
    echo "Finished setting up hosts file"
}


function generateMachinesYml()
{
    echo "Generating machines.yml file to be included as part of cluster.yml"
    
    machineYmlFile="$PHILLY_HOME/machines.yml"
    echo "#This file is generated automatically at provisioning" > $machineYmlFile

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
    while [ $i -lt $WORKER_COUNT ]
    do
        nextip=$((i + WORKER_IP_START))
        echo "    $WORKER_BASE_NAME$i:" 
        echo "      sku: $WORKERNODE_SKU" 
        echo "      rack: rack0" 
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
    
    # etcdInitialCluster=""
    # i=0
    # while [ $i -lt $INFRA_COUNT ]
    # do
    #     nextip=$((i + INFRA_IP_START))
    #     etcdInitialCluster="${etcdInitialCluster}${INFRA_BASE_NAME}$i=http://$INFRA_IP_BASE$nextip:7001,"
    #     ((++i))
    # done

    # #delete the trailing comma
    # etcdInitialCluster=${etcdInitialCluster%?}
    
    # #update cloud-config file
    # cp $PHILLY_HOME/cloud-config.yml $PHILLY_HOME/cloud-config.yml.orig

    # sed -i "s/__HOSTNAME__/$NAME/g" $PHILLY_HOME/cloud-config.yml
    # sed -i "s/__HOSTIP__/$IP/g" $PHILLY_HOME/cloud-config.yml
    # sed -i "s?__ETCD_INITIAL_CLUSTER__?$etcdInitialCluster?g" $PHILLY_HOME/cloud-config.yml

    cp $PHILLY_HOME/azure.yml $PHILLY_HOME/azure.yml.orig
    if [[ "$CLUSTERYML" -eq "none" ]] ; then
        sed -i "s/__CLUSTER__/$cluster/g" $PHILLY_HOME/azure.yml
    else
        wget $CLUSTERYML -O $PHILLY_HOME/azure.yml
        cluster=$(grep -m 1 "id: " gcr.yml | awk -F" " '{print $2}')
    fi

    cp $PHILLY_HOME/cloud-config.yml $PHILLY_HOME/cloud-config.yml.orig
    $PHILLY_HOME/tools/generate-config -c $PHILLY_HOME/azure.yml --host $NAME -t $PHILLY_HOME/cloud-config.yml.template > $PHILLY_HOME/cloud-config.yml
    
    echo "Finished updating cloud-config.yml file"
}


function slurmMasterSetup()
{
    sudo chmod g-w /var/log

    # Download slurm.conf and fill in the node info
    SLURMCONF=/tmp/slurm.conf.$$

    wget $TEMPLATE_BASE/slurm.template.conf -O $SLURMCONF
    sed -i -- 's/__MASTERNODE__/'"$NAME"'/g' $SLURMCONF

    lastvm=$((INFRA_COUNT - 1))
    sed -i -- 's/__WORKERNODES__/'"$INFRA_BASE_NAME"'[1-'"$lastvm"']/g' $SLURMCONF
    cp -f $SLURMCONF /etc/slurm-llnl/slurm.conf
    chown slurm /etc/slurm-llnl/slurm.conf
    chmod o+w /var/spool # Write access for slurmctld log. Consider switch log file to another location

    # Start the master daemon service
    sudo -u slurm /usr/sbin/slurmctld 
    munged --force
    slurmd

    #Prepare mungekey
    mungekey=/tmp/munge.key.$$
    cp -f /etc/munge/munge.key $mungekey
    chown $ADMIN_USERNAME $mungekey
    #Looping all other infranodes to setup slurm
    i=1
    while [ $i -lt $INFRA_COUNT ]
    do
        worker=$INFRA_BASE_NAME$i

        echo waiting for $worker to be ready

        second=0
        while [ -n "$(echo a|ncat $worker 8090 2>&1)" ]; do
            ((second += 5))                  
            sleep 5
        done

        echo $worker is ready after $second seconds of waiting

        #setting up slurm
        sudo -u $ADMIN_USERNAME scp $mungekey $ADMIN_USERNAME@$worker:/tmp/munge.key
        sudo -u $ADMIN_USERNAME scp $SLURMCONF $ADMIN_USERNAME@$worker:/tmp/slurm.conf
        sudo -u $ADMIN_USERNAME scp /tmp/hosts.$$ $ADMIN_USERNAME@$worker:/tmp/hosts
        sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@$worker << 'ENDSSH1'
        sudo chmod g-w /var/log
        sudo cp -f /tmp/munge.key /etc/munge/munge.key
        sudo chown munge /etc/munge/munge.key
        sudo chgrp munge /etc/munge/munge.key
        sudo rm -f /tmp/munge.key
        sudo /usr/sbin/munged --force # ignore egregrious security warning
        sudo cp -f /tmp/slurm.conf /etc/slurm-llnl/slurm.conf
        sudo chown slurm /etc/slurm-llnl/slurm.conf
        sudo slurmd
ENDSSH1

        ((++i))
    done
    rm -f $mungekey
}


function slurmSlaveSetup()
{
    ncat -v -l 8090
}


function updateResolvConf()
{
    #worker setup is not started until infra nodes are finished setting up
    #by that time dns from infra nodes are already up
    if [[ $isWorker -eq 0 ]];
    then
        while [[ -z $(netstat -nlp 2>/dev/null | grep 127.0.0.1:53) ]];
        do
            sleep 5
        done
    fi

    #Rewrite /etc/resolv.conf after dns is up
    azureInternalDomain=$(grep search /etc/resolv.conf | awk -F" " '{print $2}')
    cp /etc/resolv.conf /etc.resolv.conf.philly.bak
    cp /etc/phillyresolv.conf /etc/resolv.conf
    sed -i "s/search $cluster.philly.selfhost.corp.microsoft.com/search $cluster.philly.selfhost.corp.microsoft.com $azureInternalDomain/g" /etc/resolv.conf
}


function setupSlurm()
{
    if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then  
        slurmMasterSetup
    else
        if [[ $isWorker -eq 0 ]]; then
            slurmSlaveSetup
        fi
    fi
}


function applyCloudConfig()
{
    #Applying cloud config
    coreos-cloudinit --from-file $PHILLY_HOME/cloud-config.yml

    #Wait for fleet to be ready
    while [[ $(fleetctl list-machines | wc -l) -lt $INFRA_COUNT ]]; do sleep 2; done
}


function startCoreServices()
{
    if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then  
        
        #Push cluster config to ETCD
        $PHILLY_HOME/tools/pcm -e localhost -c $PHILLY_HOME/azure.yml pushcfg

        #Add activeNameNode key for DNS module
        etcdctl set /activeNameNode $INFRA_BASE_NAME$masterIndex

        for service in docker-registry master dns
        do
            fleetctl start $PHILLY_HOME/services/$service.service
            while [[ -n $(fleetctl list-unit --fields unit,sub | grep $service | grep -E 'dead|start-pre|auto-restart') ]];
            do
                sleep 2
            done
        done
        updateResolvConf

        fleetctl start $PHILLY_HOME/services/webserver.service
    else
        updateResolvConf
    fi
}


function startHadoopServices()
{  
    if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then
        for service in zookeeper hadoop-journal-node hadoop-name-node hadoop-data-node hadoop-resource-manager hadoop-node-manager
        do
            fleetctl start $PHILLY_HOME/services/$service.service
            while [[ -n $(fleetctl list-unit --fields unit,sub | grep $service | grep -E 'dead|start-pre|auto-restart') ]];
            do
                sleep 2
            done           
        done
        /opt/bin/hdfs mkdir -p hdfs://hnn:8020/sys/runtimes
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
        
        i=0
        while [ $i -lt $INFRA_COUNT ]
        do
            nextip=$((i + INFRA_IP_START))
            etcdctl mkdir stateMachine/$INFRA_BASE_NAME$i
            etcdctl mk stateMachine/$INFRA_BASE_NAME$i/currentState UP
            etcdctl mk stateMachine/$INFRA_BASE_NAME$i/goalState UP

            etcdctl mkdir resources/gpu/$INFRA_IP_BASE$nextip
            etcdctl mkdir resources/port/$INFRA_IP_BASE$nextip
            etcdctl mkdir resources/portRangeStart/$INFRA_IP_BASE$nextip
            ((++i))
        done

        i=0
        while [ $i -lt $WORKER_COUNT ]
        do
            nextip=$((i + INFRA_IP_START))
            etcdctl mkdir stateMachine/$WORKER_BASE_NAME$i
            etcdctl mk stateMachine/$WORKER_BASE_NAME$i/currentState UP
            etcdctl mk stateMachine/$WORKER_BASE_NAME$i/goalState UP

            etcdctl mkdir resources/gpu/$WORKER_IP_BASE$nextip
            etcdctl mkdir resources/port/$WORKER_IP_BASE$nextip
            etcdctl mkdir resources/portRangeStart/$WORKER_IP_BASE$nextip       
            ((++i))
        done

        fleetctl start $PHILLY_HOME/services/ganglia-client
        sleep 10
    fi
    
}


#
# Main script body
#
initialSetup
fixHostsFile
generateMachinesYml
updateConfigFile
setupSlurm
applyCloudConfig
startCoreServices
startHadoopServices
startOtherServices

exit 0
