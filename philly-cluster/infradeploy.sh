#!/bin/bash

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

echo "Script arguments: $*"

if [ $# != 21 ]; then
    echo "Usage: $0 <InfraCount> <AdminUserName> <AdminPassword> <InfraBaseName> <IpBase> <IpStart> <WorkerBaseName> <WorkerCount> <WorkerIpBase> <WorkerIpStart> <AuxBaseName> <AuxNodeCount> <AuxIpBase> <AuxIpStart> <TemplateBaseUrl> <InfraSKU> <WorkerSKU> <AuxSKU> <ClusterYmlUrl> <CloudConfigTemplate> <ClusterId>"
    exit 1
fi

NAME=$(hostname)

isWorker=0
if [[ $NAME == *"worker"* ]]; then isWorker=1; fi

isInfra=0
if [[ $NAME == *"infra"* ]]; then isInfra=1; fi

#This is currently hardcoded, should be passed as an argument
LOAD_BALANCER_IP=10.0.0.4

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

AUX_BASE_NAME=${11}
AUX_COUNT=${12}
AUX_IP_BASE=${13}
AUX_IP_START=${14}

TEMPLATE_BASE=${15}
HEADNODE_SKU=${16}
WORKERNODE_SKU=${17}
AUXNODE_SKU=${18}
CLUSTERYML=${19}
CLOUDCONFIG=${20}
CLUSTER=${21}

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
    mkdir /var/nfsshare

    #if there is a datadisk mounted on sdc we partition it and format it
    if [[ -z $(fdisk -l /dev/sdc 2>&1 | grep "cannot open") ]];
    then
        if [ ! -b /dev/sdc1 ];
        then
            (echo n; echo p; echo 1; echo ; echo ; echo w) | fdisk /dev/sdc
            mkfs -t ext4 /dev/sdc1
        fi
    fi

    ln -s /bin/mount /usr/bin/mount
    ln -s /sbin/sysctl /usr/sbin/sysctl
    ln -s /bin/bash /usr/bin/bash
    ln -s /bin/true /usr/bin/true
    ln -s /bin/mount /usr/bin/mount
    ln -s /bin/chmod /usr/bin/chmod

    echo "Initial setup done"
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

    i=0
    while [ $i -lt $AUX_COUNT ]
    do
        nextip=$((i + AUX_IP_START))
         echo $AUX_IP_BASE$nextip $AUX_BASE_NAME$i >> /etc/hosts
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

    #need to convert the Azure sku string to what philly likes
    HEADNODE_SKU=${HEADNODE_SKU,,} #switch to lowercase
    HEADNODE_SKU=${HEADNODE_SKU//_/-} #change dash into underscore
    WORKERNODE_SKU=${WORKERNODE_SKU,,} #switch to lowercase
    WORKERNODE_SKU=${WORKERNODE_SKU//_/-} #change dash into underscore
    AUXNODE_SKU=${AUXNODE_SKU,,} #switch to lowercase
    AUXNODE_SKU=${AUXNODE_SKU//_/-} #change dash into underscore

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
    while [ $i -lt $AUX_COUNT ]
    do
        nextip=$((i + AUX_IP_START))
        echo "    $AUX_BASE_NAME$i:"
        echo "      sku: $AUXNODE_SKU"
        echo "      rack: rack0"
        echo "      rackLocation: 1"
        echo "      outlet: 1.0"
        if [[ $i -eq 0 ]]
        then
            echo "      role: nfs"
        elif [[ $i -eq 1 ]]
        then
            echo "      role: ganglia-master"
        else
            echo "      role: auxiliary"
        fi
        echo "      mac: 00:00:00:00:00:00"
        echo "      ip: $AUX_IP_BASE$nextip"
        echo "      os: prod-infra"
        ((++i))
    done

    i=0
    while [ $i -lt $WORKER_COUNT ]
    do
        nextip=$((i + WORKER_IP_START))
        echo "    $WORKER_BASE_NAME$i:"
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
        CLUSTER=$(grep -m 1 "id: " gcr.yml | awk -F" " '{print $2}')
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
    if [[ $isInfra -eq 1 ]];
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
    sed -i "s/search $CLUSTER.philly.selfhost.corp.microsoft.com/search $CLUSTER.philly.selfhost.corp.microsoft.com $azureInternalDomain/g" /etc/resolv.conf

    #at this point dns is up, so we remove the infra and master entry from hosts file
    sed -i "s/127.0.0.1 localhost infra/127.0.0.1 localhost/g" /etc/hosts
    sed -i "s/$INFRA_IP_BASE$INFRA_IP_START master//g" /etc/hosts
}


function setupSlurm()
{
    if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then  
        slurmMasterSetup
    else
        if [[ $isInfra -eq 1 ]]; then
            slurmSlaveSetup
        fi
    fi
}


function applyCloudConfig()
{
    mkdir -p /var/lib/coreos-install
    coreos-cloudinit --from-file $PHILLY_HOME/cloud-config.yml
    if [[ -z $(id -u core 2>&1 | grep "no such user") ]]; then
        echo "core ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    fi
    
    #Wait for fleet to be ready
    while [[ $(fleetctl list-machines | wc -l) -lt $INFRA_COUNT ]]; do sleep 5; done
    cp $PHILLY_HOME/cloud-config.yml /var/lib/coreos-install/user_data

    sed -i "s/exit 0//g" /etc/rc.local
    {
        echo '[ ! -f "/var/lib/coreos-install/user_data" ] &&'
        echo '    sudo curl "http://$LOAD_BALANCER_IP/cloud-config/$(hostname).yml?reconfigure" -o /var/lib/coreos-install/user_data'
        echo '[ -f "/var/lib/coreos-install/user_data" ] &&'
        echo '    coreos-cloudinit --from-file=/var/lib/coreos-install/user_data'
        echo "#coreos-cloudinit generates a phillyresolv.conf file that we should use"
        echo "cp /etc/phillyresolv.conf /etc/resolv.conf"
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

        #Wait for all infrastructure nodes to come up
        #if upinfra is not up webserver will start ok but not answering http request
        i=0
        while [ $i -lt $INFRA_COUNT ]
        do
            nextip=$((i + INFRA_IP_START))
            dnsServer=$INFRA_IP_BASE$nextip
            until nslookup upinfra $dnsServer; do sleep 5; done;
        done
        
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

    if [ "$NAME" == "$WORKER_BASE_NAME$masterIndex" ] ; then
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
        while [ $i -lt $AUX_COUNT ]
        do
            nextip=$((i + AUX_IP_START))
            etcdctl mkdir stateMachine/$AUX_BASE_NAME$i
            etcdctl mk stateMachine/$AUX_BASE_NAME$i/currentState UP
            etcdctl mk stateMachine/$AUX_BASE_NAME$i/goalState UP

            etcdctl mkdir resources/gpu/$AUX_IP_BASE$nextip
            etcdctl mkdir resources/port/$AUX_IP_BASE$nextip
            etcdctl mkdir resources/portRangeStart/$AUX_IP_BASE$nextip
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
        startService ganglia-client
    fi
}


function enableRDMA()
{
    if [[ $isWorker -eq 1 && "$WORKERNODE_SKU" == "standard-nc24rs-v2" ]];
    then
        {
            echo "#Enable RDMA"
            echo "OS.EnableRDMA=y"
            echo "OS.UpdateRdmaDriver=y"
        } >> /etc/waagent.conf
    fi
}


function startNfs()
{
    #
    # Query etcd to find out if this machine is responsible for nfs server
    # (If etcd is not up we have a bigger problem than starting nfs)
    #
    if [[ $isInfra -eq 0 ]]; then       
        if [[ $(etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" get /config/machines/$NAME/role) == "nfs" ]];
        then
            systemctl restart nfs-kernel-server
            sleep 10

            startServiceWaitForExited nfs-mount
            startServiceWaitForRunning hadoop-node-manager
        fi
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
startNfs
startHadoopServices
startOtherServices
enableRDMA
exit 0
