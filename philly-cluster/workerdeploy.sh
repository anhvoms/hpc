#!/bin/bash

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

echo "Script arguments: $@"

if [ $# != 12 ]; then
    echo "Usage: $0 <WorkerName> <WorkerCount> <AdminUserName> <AdminUserPassword> <InfraBaseName> <IpBase> <IpStart> <WorkerBaseName> <WorkerNodeCount> <WorkerIpBase> <WorkerIpStart> <TemplateBaseUrl>"
    exit 1
fi

NAME=$1
IP=`ifconfig eth0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'`

NUMNODES=$2
ADMIN_USERNAME=$3
ADMIN_PASSWORD=$4
INFRA_BASE_NAME=$5
IPBASE=$6
IPSTART=$7

WORKER_BASE_NAME=$8
WORKERCOUNT=$9
WORKERIPBASE=$10
WORKERIPSTART=$11
TEMPLATE_BASE=$12

#entries for master node
echo $IPBASE$IPSTART master >> /etc/hosts
echo $IP $NAME >> /etc/hosts

# Don't require password for admin sudo
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

#entries for infra nodes
i=0
   while [ $i -lt $NUMNODES ]
   do
       nextip=`expr $i + $IPSTART`
       echo $IPBASE$nextip $INFRA_BASE_NAME$i >> /etc/hosts
       i=`expr $i + 1`
   done
   ncat -v -l 8090
fi

#entries for worker nodes
i=0
while [ $i -lt $WORKERCOUNT ]
do
   nextip=`expr $i + $WORKERIPSTART`
   echo $WORKERIPBASE$nextip $WORKER_BASE_NAME$i >> /etc/hosts
   i=`expr $i + 1`
done
