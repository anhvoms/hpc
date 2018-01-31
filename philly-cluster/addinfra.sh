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
    [[ ! -d /var/nfshare ]] && mkdir /var/nfsshare
    [[ ! -d /var/nfs-mount ]] && mkdir /var/nfs-mount
    [[ ! -d /var/gfs ]] && mkdir /var/gfs

    #if there is a datadisk mounted on sdc we partition it and format it
    if [[ -z $(fdisk -l /dev/sdc 2>&1 | grep "cannot open") ]];
    then
        if [ ! -b /dev/sdc1 ];
        then
            (echo n; echo p; echo 1; echo ; echo ; echo w) | fdisk /dev/sdc
            mkfs -t ext4 /dev/sdc1
        fi
    fi

    [[ ! -f /usr/bin/mount ]] && ln -s /bin/mount /usr/bin/mount
    [[ ! -f /usr/sbin/sysctl ]] && ln -s /sbin/sysctl /usr/sbin/sysctl
    [[ ! -f /usr/bin/bash ]] && ln -s /bin/bash /usr/bin/bash
    [[ ! -f /usr/bin/true ]] && ln -s /bin/true /usr/bin/true
    [[ ! -f /usr/bin/chmod ]] && ln -s /bin/chmod /usr/bin/chmod

    echo "Initial setup done"
}


function applyCloudConfig()
{
    [[ ! -d /var/lib/coreos-install ]] && mkdir -p /var/lib/coreos-install
    curl "http://$LOAD_BALANCER_IP/cloud-config/$NAME.yml?reconfigure" -o /var/lib/coreos-install/user_data
    [[ -f "/var/lib/coreos-install/user_data" ]] && coreos-cloudinit --from-file=/var/lib/coreos-install/user_data

    if [[ -z $(id -u core 2>&1 | grep "no such user") ]]; then
        echo "core ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
        usermod -a -G systemd-journal core
    fi
    
    sed -i "s/exit 0//g" /etc/rc.local
    {
        echo "LOAD_BALANCER_IP=$LOAD_BALANCER_IP"
        echo '[[ ! -f "/var/lib/coreos-install/user_data" ]] &&'
        echo '    sudo curl "http://$LOAD_BALANCER_IP/cloud-config/$(hostname).yml?reconfigure" -o /var/lib/coreos-install/user_data'
        echo '[[ -f "/var/lib/coreos-install/user_data" ]] &&'
        echo '    coreos-cloudinit --from-file=/var/lib/coreos-install/user_data'
    } >> /etc/rc.local

    /etc/init.d/docker restart
}


function updateStateMachineStatus()
{
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" mkdir /stateMachine/$NAME
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" set /stateMachine/$NAME/currentState "UP/ok"
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" set /stateMachine/$NAME/goalState UP
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" mkdir /resources/gpu/$IP
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" mkdir /resources/port/$IP
    etcdctl --endpoints "http://$LOAD_BALANCER_IP:4001" mkdir /resources/portRangeStart/$IP
}


initialSetup
#applyCloudConfig
#sleep 20
#updateStateMachineStatus
#enableRDMA
