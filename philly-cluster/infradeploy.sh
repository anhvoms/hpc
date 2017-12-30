#!/bin/bash

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

echo "Script arguments: $@"

if [ $# != 8 ]; then
    echo "Usage: $0 <MasterName> <InfraNodeCount> <AdminUserName> <AdminUserPassword> <InfraBaseName> <IpBase> <IpStart> <TemplateBaseUrl>"
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
TEMPLATE_BASE=$8

echo $IP $NAME >> /etc/hosts

masterIndex=0

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

if [ "$NAME" == "$INFRA_BASE_NAME$masterIndex" ] ; then
   
   #setup ssh key for this particular node
   # mkdir -p /home/$ADMIN_USERNAME/.ssh
   # echo -e  'y\n' | ssh-keygen -f /home/$ADMIN_USERNAME/.ssh/id_rsa -t rsa -N ''
   # echo 'Host *' >> /home/$ADMIN_USERNAME/.ssh/config
   # echo 'StrictHostKeyChecking no' >> /home/$ADMIN_USERNAME/.ssh/config
   # chmod 400 /home/$ADMIN_USERNAME/.ssh/config
   # chown $ADMIN_USERNAME:$ADMIN_USERNAME /home/$ADMIN_USERNAME/.ssh/config

   # mkdir -p ~/.ssh
   # echo 'Host *' >> ~/.ssh/config
   # echo 'StrictHostKeyChecking no' >> ~/.ssh/config
   # chmod 400 ~/.ssh/config

   # #install sshpass if necessary,
   # command -v sshpass >/dev/null 2>&1 || {apt-get install sshpass -y}
    

   # #Loop through all infra nodes and copy ssh key
   # i=0
   # while [ $i -lt $NUMNODES ]
   # do
   #     nextip=`expr $i + $IPSTART`
   #     echo $IPBASE$nextip $INFRA_BASE_NAME$i >> /etc/hosts      
       
   #     sshpass -p "$ADMIN_PASSWORD" ssh $ADMIN_USERNAME@$INFRA_BASE_NAME$i "mkdir -p .ssh"
   #     cat /home/$ADMIN_USERNAME/.ssh/config | sshpass -p "$ADMIN_PASSWORD" ssh $ADMIN_USERNAME@$INFRA_BASE_NAME$i "cat >> .ssh/config"
   #     cat /home/$ADMIN_USERNAME/.ssh/id_rsa | sshpass -p "$ADMIN_PASSWORD" ssh $ADMIN_USERNAME@$INFRA_BASE_NAME$i "cat >> .ssh/id_rsa"
   #     cat /home/$ADMIN_USERNAME/.ssh/id_rsa.pub | sshpass -p "$ADMIN_PASSWORD" ssh $ADMIN_USERNAME@$INFRA_BASE_NAME$i "cat >> .ssh/authorized_keys"
   #     sshpass -p "$ADMIN_PASSWORD" ssh $ADMIN_USERNAME@$INFRA_BASE_NAME$i "chmod 700 .ssh; chmod 640 .ssh/authorized_keys; chmod 400 .ssh/config; chmod 400 .ssh/id_rsa"       
       
   #     i=`expr $i + 1`
   # done

   # chown -R $ADMIN_USERNAME:$ADMIN_USERNAME /home/$ADMIN_USERNAME/.ssh/
   # chown -R $ADMIN_USERNAME:$ADMIN_USERNAME /home/$ADMIN_USERNAME/bin/

   sudo chmod g-w /var/log

   # Download slurm.conf and fill in the node info
   SLURMCONF=/tmp/slurm.conf.$$

   wget $TEMPLATE_BASE/slurm.template.conf -O $SLURMCONF
   sed -i -- 's/__MASTERNODE__/'"$NAME"'/g' $SLURMCONF

   lastvm=`expr $NUMNODES - 1`
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
   while [ $i -lt $NUMNODES ]
   do
       worker=$INFRA_BASE_NAME$i

       echo waiting for $worker to be ready

       sec=0
       until nmap -p 8080 $worker | grep -q open; do
           sleep 1
           sec=`expr $sec +1`
       done
       echo $worker is ready after $sec seconds of waiting
       
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

      i=`expr $i + 1`
   done
   rm -f $mungekey
else
    
   i=0
   while [ $i -lt $NUMNODES ]
   do
       nextip=`expr $i + $IPSTART`
       echo $IPBASE$nextip $INFRA_BASE_NAME$i >> /etc/hosts
       i=`expr $i + 1`
   done
   ncat -l 8080
fi

exit 0
