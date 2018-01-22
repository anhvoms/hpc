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

initialSetup
