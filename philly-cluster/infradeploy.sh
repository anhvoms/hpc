#!/bin/bash

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

echo "Script arguments: $*"

if [ $# != 11 ]; then
    echo "Usage: $0 <InfraNodeCount> <AdminUserName> <AdminUserPassword> <InfraBaseName> <IpBase> <IpStart> <WorkerBaseName> <WorkerNodeCount> <WorkerIpBase> <WorkerIpStart> <TemplateBaseUrl>"
    exit 1
fi

NAME=$(hostname)
IP=$(ifconfig eth0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')

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

masterIndex=0

function initialSetup()
{
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
    cp /var/lib/philly/bootstrap/.ssh/* /home/$ADMIN_USERNAME/.ssh
    cp /var/lib/philly/bootstrap/.ssh/* ~/.ssh
    
    chmod 700 /home/$ADMIN_USERNAME/.ssh
    chmod 400 /home/$ADMIN_USERNAME/.ssh/config
    chmod 640 /home/$ADMIN_USERNAME/.ssh/authorized_keys
    chmod 400 /home/$ADMIN_USERNAME/.ssh/id_rsa
    chown -R $ADMIN_USERNAME:$ADMIN_USERNAME /home/$ADMIN_USERNAME/.ssh
}


function fixHostsFile()
{
    #fix up hosts file
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
}


function generateMachinesYml()
{
    machineYmlFile="/var/lib/philly/machines.yml"
    echo "#This file is generated automatically at provisioning" > $machineYmlFile

    {
    i=0
    while [ $i -lt $INFRA_COUNT ]
    do              
        nextip=$((i + INFRA_IP_START))
        echo "    $INFRA_BASE_NAME$i:" 
        echo "      sku: standard-d4s-v3" 
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
        echo "      sku: standard-nc6" 
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
}


function updateConfigFile()
{
    etcdInitialCluster=""
    i=0
    while [ $i -lt $INFRA_COUNT ]
    do
        nextip=$((i + INFRA_IP_START))
        etcdInitialCluster="${etcdInitialCluster}${INFRA_BASE_NAME}$i=http://$INFRA_IP_BASE$nextip:7001,"
        ((++i))
    done

    #delete the trailing comma
    etcdInitialCluster=${etcdInitialCluster%?}
    
    #update cloud-config file
    cp /var/lib/philly/cloud-config.yml /var/lib/philly/cloud-config.yml.orig

    sed -i "s/__HOSTNAME__/$NAME/g" /var/lib/philly/cloud-config.yml
    sed -i "s/__HOSTIP__/$IP/g" /var/lib/philly/cloud-config.yml
    sed -i "s?__ETCD_INITIAL_CLUSTER__?$etcdInitialCluster?g" /var/lib/philly/cloud-config.yml

    cp /var/lib/philly/azure.yml /var/lib/philly/azure.yml.orig
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


#
# Main script body
#
initialSetup
fixHostsFile
generateMachinesYml
updateConfigFile

if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then  
    slurmMasterSetup
else
    slurmSlaveSetup
fi

echo "All READY - invoking CoreOS-cloudinit"
coreos-cloudinit --from-file /var/lib/philly/cloud-config.yml

exit 0
