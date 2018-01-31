#!/bin/bash
# This script is to install and config software for GlusterFS Linux node

if [ $# -lt 4 ]; then
    echo usage: $0 [node_prefix] [ip_base] [offset] [node_count] 
    echo ""
    echo "- [node_prefix] name prefix of GlusterFS nodes"
    echo "- [ip_base] IP address base for GlusterFS nodes. E.g. 10.1.1"
    echo "- [offset] ip address offset"
    echo "- [node_count] number of GlusterFS nodes"
    echo ""
    exit 1
fi

# Import common functions
echo "Starting installation and configuration on $HOSTNAME"

LOAD_BALANCER_IP=10.0.0.4
ADMIN_USERNAME=philly
PHILLY_HOME=/var/lib/philly
NAME=$(hostname)
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

initialSetup

echo "- Starting GlusterFS node configuration"
hostprefix=$1
ipbase=$2
offset=$3
nodecount=$4
#vnetAddressSpace=${ipbase%?}*.*
private_ips=()
# Create static private IPs that follow Azure numbering scheme with specified offset
for (( i=$offset; i<$((nodecount+offset)); i++ )); do
    private_ips+=($ipbase.$i)
done

# Construct bootstrap command that downloaded from
# https://raw.githubusercontent.com/Azure/batch-shipyard/master/scripts/shipyard_remotefs_bootstrap.sh
# Usage:
#   shipyard_remotefs_bootstrap.sh parameters
# Parameters:
#   -a attach mode
#   -b rebalance filesystem on resize
#   -c [share_name:username:password:uid:gid:ro:create_mask:directory_mask] samba options
#   -d [hostname/dns label prefix] hostname prefix
#   -f [filesystem] filesystem
#   -i [peer IPs] peer IPs
#   -m [mountpoint] mountpoint
#   -n Tune TCP parameters
#   -o [server options] server options
#   -p premium storage disks
#   -r [RAID level] RAID level
#   -s [server type] server type
#   -t [mount options] mount options
hostPrefixOption='-d '$hostprefix
fileSystemOption='-f ext4'
peerIPsOption='-i '$(IFS=, ; echo "${private_ips[*]}")
mountpointOption='-m /data'
tuneTcpOption='-n'
#serverOption='gv0,replica 3,tcp,performance.cache-size:1GB,auth.allow:'$vnetAddressSpace
serverOption='gv0,replica 3,tcp'
premiumOption='-p'
raidLevelOption='-r 0'
serverTypeOption='-s glusterfs'
mountOption='-t noatime,nodiratime'

#Change shipyard script to allow our vm naming pattern
sed -i 's/vm$i/vm$(seq -f "%03g" $i $i)/g' ./shipyard_remotefs_bootstrap.sh

echo "Executing shipyard_remotefs_bootstrap.sh $hostPrefixOption $fileSystemOption $peerIPsOption $mountpointOption $tuneTcpOption -o $serverOption $premiumOption $raidLevelOption $serverTypeOption $mountOption"
./shipyard_remotefs_bootstrap.sh $hostPrefixOption $fileSystemOption $peerIPsOption $mountpointOption $tuneTcpOption -o "$serverOption" $premiumOption $raidLevelOption $serverTypeOption $mountOption
exitCode=$?

if [ $exitCode -ne 0 ]; then
    echo "##ERROR failed to run shipyard_remotefs_bootstrap.sh with exit code: $exitCode"
    exit $exitCode
fi

echo "Completed the gluster setup on $(hostname)"

applyCloudConfig
exit 0
