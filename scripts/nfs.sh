#!/bin/bash

function log()
{
  message=$@
  echo "$message"
  echo "$message" >> /var/log/sapconfigcreate
}

function getdevicepath()
{

  log "getdevicepath"
  getdevicepathresult=""
  local lun=$1
  local readlinkOutput=$(readlink /dev/disk/azure/scsi1/lun$lun)
  local scsiOutput=$(lsscsi)
  if [[ $readlinkOutput =~ (sd[a-zA-Z]{1,2}) ]];
  then
    log "found device path using readlink"
    getdevicepathresult="/dev/${BASH_REMATCH[1]}";
  elif [[ $scsiOutput =~ \[5:0:0:$lun\][^\[]*(/dev/sd[a-zA-Z]{1,2}) ]];
  then
    log "found device path using lsscsi"
    getdevicepathresult=${BASH_REMATCH[1]};
  else
    log "lsscsi output not as expected for $lun"
    exit -1;
  fi
  log "getdevicepath done"

}

function createlvm()
{
  
  log "createlvm"

  lunsA=(${1//,/ })
  vgName=$2
  lvName=$3

  arraynum=${#lunsA[@]}
  log "count $arraynum"
  
  log "createlvm - creating lvm"

  numRaidDevices=0
  raidDevices=""
  num=${#lunsA[@]}
  log "num luns $num"
  
  for ((i=0; i<num; i++))
  do
    log "trying to find device path"
    lun=${lunsA[$i]}
    getdevicepath $lun
    devicePath=$getdevicepathresult;
    
    if [ -n "$devicePath" ];
    then
      log " Device Path is $devicePath"
      numRaidDevices=$((numRaidDevices + 1))
      raidDevices="$raidDevices $devicePath "
    else
      log "no device path for LUN $lun"
      exit -1;
    fi
  done

  log "num: $numRaidDevices paths: '$raidDevices'"
  $(pvcreate $raidDevices)
  $(vgcreate $vgName $raidDevices)
  $(lvcreate --extents 100%FREE --stripes $numRaidDevices --name $lvName $vgName)
  $(mkfs -t xfs /dev/$vgName/$lvName)

  log "createlvm done"
}

log $@

luns=""
node=0
lbip=""
lbname=""
ipnode0=""
ipnode1=""
hostnode0=""
hostnode1=""

while true; 
do
  case "$1" in
    "-luns")  luns=$2;shift 2;log "found luns"
    ;;
    "-node")  node=$2;shift 2;log "found node"
    ;;
    "-lbip")  lbip=$2;shift 2;log "found lbip"
    ;;
    "-lbname")  lbname=$2;shift 2;log "found lbname"
    ;;
    "-ipnode0")  ipnode0=$2;shift 2;log "found ipnode0"
    ;;
    "-ipnode1")  ipnode1=$2;shift 2;log "found ipnode1"
    ;;
    "-hostnode0")  hostnode0=$2;shift 2;log "found hostnode0"
    ;;
    "-hostnode1")  hostnode1=$2;shift 2;log "found hostnode1"
    ;;
    *) log "unknown parameter $1";shift 1;
    ;;
  esac

  if [[ -z "$1" ]];
  then 
    break; 
  fi
done

log "running with $luns $node $lbip $lbname $ipnode0 $ipnode1 $hostnode0 $hostnode1"

if [[ $node -eq 0 ]]
then
  log "running on node 0"
  myip=$ipnode0
  otherip=$ipnode1
  myhost=$hostnode0
  otherhost=$hostnode1
else
  log "running on node 1"
  myip=$ipnode1
  otherip=$ipnode0
  myhost=$hostnode1
  otherhost=$hostnode0
fi

log "installing packages"
zypper install -y -l sle-ha-release fence-agents drbd drbd-kmp-default drbd-utils

createlvm $luns "vg_NFS" "lv-NFS"

log "fixing hosts"
hosts=$(cat /etc/hosts)
if [[ $hosts =~  $lbip ]]
then
  log "host already in /etc/hosts"
else  
  log "host not in /etc/hosts"
  echo "$lbip $lbname" >> /etc/hosts
fi
if [[ $hosts =~  $myip ]]
then
  log "my host already in /etc/hosts"
else  
  log "my host not in /etc/hosts"
  echo "$myip $myhost" >> /etc/hosts
fi
if [[ $hosts =~  $otherip ]]
then
  log "my host already in /etc/hosts"
else  
  log "my host not in /etc/hosts"
  echo "$otherhost $otherip" >> /etc/hosts
fi

if [[ $node -eq 0 ]]
then
  ssh-keygen -tdsa -f /root/.ssh/id_dsa -N ""
  log "creating cluster"
  # ha-cluster-init -y csync2
  # ha-cluster-init -y -u corosync
  # ha-cluster-init -y cluster
else
  ssh-keygen -tdsa -f /root/.ssh/id_dsa -N ""
  log "joining cluster"
  # ha-cluster-join -y -c $otherhost csync2
  # ha-cluster-join -y -c $otherhost ssh_merge
  # ha-cluster-join -y -c $otherhost cluster    
fi

#passwd hacluster TODO

# sudo vi /etc/corosync/corosync.conf
# [...]
#   interface { 
#      [...] 
#   }
#   transport:      udpu
# } 
# nodelist {
#   node {
#    # IP address of prod-nfs-0
#    ring0_addr:10.0.0.5
#   }
#   node {
#    # IP address of prod-nfs-1
#    ring0_addr:10.0.0.6
#   } 
# }
# logging {
#   [...]


# service corosync restart

# vi /etc/drbd.d/NWS_nfs.res
# resource NWS_nfs {
#    protocol     C;
#    disk {
#       on-io-error       pass_on;
#    }
#    on prod-nfs-0 {
#       address   10.0.0.5:7790;
#       device    /dev/drbd0;
#       disk      /dev/vg_NFS/NWS;
#       meta-disk internal;
#    }
#    on prod-nfs-1 {
#       address   10.0.0.6:7790;
#       device    /dev/drbd0;
#       disk      /dev/vg_NFS/NWS;
#       meta-disk internal;
#    }
# }
# drbdadm create-md NWS_nfs
# drbdadm up NWS_nfs
# if [[ $node -eq 1 ]]
# then
#   drbdadm new-current-uuid --clear-bitmap NWS_nfs
#   drbdadm primary --force NWS_nfs
#   mkfs.xfs /dev/drbd0
# fi