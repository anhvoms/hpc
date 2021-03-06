#!/bin/bash
# This script is to install and config software for GlusterFS Linux node

if [ $# -lt 6 ]; then
    echo usage: $0 [load_balancer_ip] [admin_username] [node_prefix] [ip_base] [offset] [node_count] [incremental]
    echo ""
    echo "- [load_balancer_ip] IP address of internal load balancer"
    echo "- [admin_username] admin username"
    echo "- [node_prefix] name prefix of GlusterFS nodes"
    echo "- [ip_base] IP address base for GlusterFS nodes. E.g. 10.1.1"
    echo "- [offset] ip address offset"
    echo "- [node_count] number of GlusterFS nodes"
    echo "- [incremental] whether these nodes are meant to be added to existing glusterfs nodes"
    echo ""
    exit 1
fi

# Import common functions
echo "Starting installation and configuration on $HOSTNAME"

LOAD_BALANCER_IP=$1
ADMIN_USERNAME=$2
PHILLY_HOME=/var/lib/philly

source ./common.sh

initialSetup $ADMIN_USERNAME $PHILLY_HOME

echo "- Starting GlusterFS node configuration"

hostprefix=$3
ipbase=$4
offset=$5
nodecount=$6
brickOnlyOption=

if [ ! -z $7 ] && [ $7 -eq 1 ]
then
    brickOnlyOption="-l"
fi

#vnetAddressSpace=${ipbase%?}*.*
private_ips=()
# Create static private IPs that follow Azure numbering scheme with specified offset
for (( i=$offset; i<$((nodecount+offset)); i++ )); do
    private_ips+=($ipbase.$i)
done

# Construct bootstrap command that downloaded from
# glusterfs_setup.sh
# Usage:
#   glusterfs_setup.sh parameters
# Parameters:
#   -a attach mode
#   -b rebalance filesystem on resize
#   -c [share_name:username:password:uid:gid:ro:create_mask:directory_mask] samba options
#   -d [hostname/dns label prefix] hostname prefix
#   -f [filesystem] filesystem
#   -i [peer IPs] peer IPs
#   -l [layout brick only]
#   -m [mountpoint] mountpoint
#   -n Tune TCP parameters
#   -o [server options] server options
#   -p premium storage disks
#   -r [RAID level] RAID level
#   -s [server type] server type
#   -t [mount options] mount options
hostPrefixOption='-d '$hostprefix
fileSystemOption='-f xfs'
peerIPsOption='-i '$(IFS=, ; echo "${private_ips[*]}")
mountpointOption='-m /data'
tuneTcpOption='-n'
#serverOption='gv0,replica 3,tcp,performance.cache-size:4GB,auth.allow:'$vnetAddressSpace
serverOption='gv0,replica 3,tcp'
premiumOption='-p'
raidLevelOption='-r 0'
serverTypeOption='-s glusterfs'
mountOption='-t relatime,nodiratime'

echo "Executing glusterfs_setup.sh $hostPrefixOption $fileSystemOption $peerIPsOption $mountpointOption $tuneTcpOption -o $serverOption $premiumOption $raidLevelOption $serverTypeOption $mountOption $brickOnlyOption"
./glusterfs_setup.sh $hostPrefixOption $fileSystemOption $peerIPsOption $mountpointOption $tuneTcpOption -o "$serverOption" $premiumOption $raidLevelOption $serverTypeOption $mountOption $brickOnlyOption
exitCode=$?

if [ $exitCode -ne 0 ]; then
    echo "##ERROR failed to run glusterfs_setup.sh with exit code: $exitCode"
    exit $exitCode
fi

echo "Completed the gluster setup on $(hostname)"

if [[ $LOAD_BALANCER_IP != "none" ]]; then
    applyCloudConfig $LOAD_BALANCER_IP
fi
exit 0
