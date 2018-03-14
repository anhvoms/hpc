#!/bin/bash

#
# Common functionalities go here
#

function initialSetup()
{
    ADMIN_USERNAME=$1
    PHILLY_HOME=$2
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

    [[ ! -d /var/nfsshare ]] && mkdir /var/nfsshare
    [[ ! -d /var/nfs-mount ]] && mkdir /var/nfs-mount
    [[ ! -d /var/gfs ]] && mkdir /var/gfs
    [[ ! -d /var/blob ]] && mkdir /var/blob

    [[ ! -f /usr/bin/mount ]] && ln -s /bin/mount /usr/bin/mount
    [[ ! -f /usr/sbin/sysctl ]] && ln -s /sbin/sysctl /usr/sbin/sysctl
    [[ ! -f /usr/bin/bash ]] && ln -s /bin/bash /usr/bin/bash
    [[ ! -f /usr/bin/true ]] && ln -s /bin/true /usr/bin/true
    [[ ! -f /usr/bin/chmod ]] && ln -s /bin/chmod /usr/bin/chmod

    echo '{ "insecure-registries":["master:5000", "upinfra:5000"] }' > /etc/docker/daemon.json
    echo "Initial setup done"
}


function applyCloudConfig()
{
    LOAD_BALANCER_IP=$1
    [[ ! -d /var/lib/coreos-install ]] && mkdir -p /var/lib/coreos-install
    curl "http://$LOAD_BALANCER_IP/cloud-config/$(hostname).yml?reconfigure" -o /var/lib/coreos-install/user_data
    [[ -f "/var/lib/coreos-install/user_data" ]] && coreos-cloudinit --from-file=/var/lib/coreos-install/user_data

    if [[ -z $(id -u core 2>&1 | grep "no such user") ]]; then
        echo "core ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
        usermod -a -G systemd-journal core
    fi
 
    sed -i "s/exit 0//g" /etc/rc.local
    {
        echo "LOAD_BALANCER_IP=$LOAD_BALANCER_IP"
        echo '[ ! -f "/var/lib/coreos-install/user_data" ] &&'
        echo '    sudo curl "http://$LOAD_BALANCER_IP/cloud-config/$(hostname).yml?reconfigure" -o /var/lib/coreos-install/user_data'
        echo '[ -f "/var/lib/coreos-install/user_data" ] &&'
        echo '    coreos-cloudinit --from-file=/var/lib/coreos-install/user_data'
    } >> /etc/rc.local

    /etc/init.d/docker restart
}


function waitForDevice() {
    local device=$1
    local START=$(date -u +"%s")
    echo "Waiting for device $device..."
    while [ ! -b $device ]; do
        local NOW=$(date -u +"%s")
        local DIFF=$((($NOW-$START)/60))
        # fail after 5 minutes of waiting
        if [ $DIFF -ge 5 ]; then
            echo "Could not find device $device"
            exit 1
        fi
        sleep 1
    done
}

function formatDatadisks()
{
    declare -a data_disks
    all_disks=($(lsblk -l -d -n -p -I 8,65,66,67,68 -o NAME))
    for disk in "${all_disks[@]}"; do
    # ignore os and ephemeral disks
    if [ $disk != "/dev/sda" ] && [ $disk != "/dev/sdb" ]; then
        data_disks=("${data_disks[@]}" "$disk")
    fi
    done
    unset all_disks
    numdisks=${#data_disks[@]}
    echo "found $numdisks data disks: ${data_disks[@]}"

    # check if data disks are already partitioned
    declare -a skipped_part
    for disk in "${data_disks[@]}"; do
    part1=$(partprobe -d -s $disk | cut -d' ' -f4)
    if [ -z $part1 ]; then
        echo "$disk: partition 1 not found. Partitioning $disk."
        parted -a opt -s $disk mklabel gpt mkpart primary 0% 100%
        part1=$(partprobe -d -s $disk | cut -d' ' -f4)
        if [ -z $part1 ]; then
        echo "$disk: partition 1 not found after partitioning."
        exit 1
        fi
        # wait for block device
        waitForDevice $disk$part1
    else
        echo "$disk: partition 1 found. Skipping partitioning."
        skipped_part=("${skipped_part[@]}" "$disk")
    fi
        mkfs -t ext4 $disk$part1
    done
}
