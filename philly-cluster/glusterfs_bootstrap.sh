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
log "Starting installation and configuration on $HOSTNAME"

log "- Starting GlusterFS node configuration"
hostprefix=$1
ipbase=$2
offset=$3
nodecount=$4
#vnetAddressSpace=${ipbase%?}*.*
private_ips=()
# Create static private IPs that follow Azure numbering scheme: start offset at 4
for (( i=4; i<$((nodecount+offset)); i++ )); do
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
#serverOption='gv0,replica 3,tcp,performance.cache-size:1GB,auth.allow:'$vnetAddressSpace # -o server options
serverOption='gv0,replica 3,tcp'# -o server options
premiumOption='-p'
raidLevelOption='-r 0'
serverTypeOption='-s glusterfs'
mountOption='-t noatime,nodiratime'

log "Creating UFW app profile for GlusterFS to unblock GlusterFS networking"
cat > /etc/ufw/applications.d/ufw-glusterfs << EOF
[GlusterFS]
title=GlusterFS
description=GlusterFS is an open source, distributed file system capable of scaling to several petabytes
ports=111,2049,24007:24011,38465:38469,49152:49215/tcp|111/udp
EOF
log "Executing shipyard_remotefs_bootstrap.sh -c $sambaOption $hostPrefixOption $fileSystemOption $peerIPsOption $mountpointOption $tuneTcpOption -o $serverOption $premiumOption $raidLevelOption $serverTypeOption $mountOption"
./shipyard_remotefs_bootstrap.sh $hostPrefixOption $fileSystemOption $peerIPsOption $mountpointOption $tuneTcpOption -o "$serverOption" $premiumOption $raidLevelOption $serverTypeOption $mountOption
exitCode=$?


if [ $exitCode -ne 0 ]; then
    log "##ERROR failed to run shipyard_remotefs_bootstrap.sh with exit code: $exitCode"
    exit $exitCode
fi

log "Completed the installation and configuration on $HOSTNAME"
exit 0