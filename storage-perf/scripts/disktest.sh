#!/bin/bash

dl=cdefghijklmnopqrstuvwxyz
part=

#init and mount data disk
if [ ! -d "/datadisk" ]; then

	apt-get -y update > /dev/null
	apt-get --no-install-recommends -y install mdadm > /dev/null

#	for i in `seq 1 $6`; do
		
#			(echo n; echo p; echo 1; echo; echo; echo w) | fdisk /dev/sd${dl:$i-1:1} > /dev/null 
#			part="$part /dev/sd${dl:$i-1:1}1"
		
#	done

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
			wait_for_device $disk$part1
		else
			echo "$disk: partition 1 found. Skipping partitioning."
			skipped_part=("${skipped_part[@]}" "$disk")
		fi
	done

    declare -a raid_array
    declare -a all_raid_disks
    set +e
    for disk in "${data_disks[@]}"; do
        mdadm --examine "${disk}1"
        if [ $? -ne 0 ]; then
            raid_array=("${raid_array[@]}" "${disk}1")
        fi
        all_raid_disks=("${all_raid_disks[@]}" "${disk}1")
    done
    set -e

	mdadm --create /dev/md1 --level 0 --raid-devices $numdisks ${raid_array[@]} > /dev/null
	
	mkfs -t ext4 /dev/md1 > /dev/null 
	
	mkdir /datadisk 
	mount /dev/md1 /datadisk

	echo "UUID=$(blkid | grep -oP '/dev/md1: UUID="*"\K[^"]*')   /datadisk   ext4   defaults   1   2" >> /etc/fstab
	chmod go+w /datadisk
fi
 

confdir=/opt/vmdiskperf/
if [ ! -d "$confdir" ]; then
	firstrun=true
	mkdir "$confdir"

	#install fio
	apt-get update > /dev/null 
	apt-get -y install fio > /dev/null
fi

#create test config
cd "$confdir"
cat << EOF > t
[global]
size=$1
direct=1
iodepth=256
ioengine=libaio
bs=$5
EOF

for i in `seq 1 $4`; do
		echo "[w$i]" >> t
		echo rw=$2 >> t
		echo directory=/datadisk >> t
done

#run test
if [ $firstrun = true ]; then
	fio --runtime $3 t | grep -E 'READ:|WRITE:' | tr '\n' ';' | tr -s [:space:] | sed 's/ :/:/g' | sed 's/= /=/g'
else
	fio --runtime $3 t 
fi