#!/bin/bash

function log()
{
  message=$@
  echo "$message"
  echo "$message" >> /var/log/sapconfigcreate
}

function addtofstab()
{
  log "addtofstab"
  partPath=$1
  mount=$2
  if [ "$mount" = true ] ;
  then
    local blkid=$(/sbin/blkid $partPath)
    
    if [[ $blkid =~  UUID=\"(.{36})\" ]]
    then
    
      log "Adding fstab entry"
      local uuid=${BASH_REMATCH[1]};
      local mountCmd=""
      log "adding fstab entry"
      mountCmd="/dev/disk/by-uuid/$uuid $mountPath xfs  defaults,nofail  0  2"
      echo "$mountCmd" >> /etc/fstab
      $(mount $mountPath)
    
    else
      log "no UUID found"
      exit -1;
    fi
  else
    $(mount $partPath $mountPath)
  fi
  
  log "addtofstab done"
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
  mountPath=$4
  mount=$5

  arraynum=${#lunsA[@]}
  log "count $arraynum"
  if [[ $arraynum -gt 1 ]]
  then
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
    $(mkdir -p $mountPath)
    
    addtofstab /dev/$vgName/$lvName  mount
  else
    log "createlvm - creating single disk"

    lun=${lunsA[0]}
    getdevicepath $lun;
    devicePath=$getdevicepathresult;
    if [ -n "$devicePath" ];
    then
      log " Device Path is $devicePath"
      # http://superuser.com/questions/332252/creating-and-formating-a-partition-using-a-bash-script
      $(echo -e "n\np\n1\n\n\nw" | fdisk $devicePath) > /dev/null
      partPath="$devicePath""1"
      $(mkfs -t xfs $partPath) > /dev/null
      $(mkdir -p $mountPath)

      addtofstab $partPath mount
    else
      log "no device path for LUN $lun"
      exit -1;
    fi
  fi

  log "createlvm done"
}

log $@

luns=""
names=""
paths=""

while true; 
do
  case "$1" in
    "-luns")  luns=$2;shift 2;log "found luns"
    ;;
    "-names")  names=$2;shift 2;log "found names"
    ;;
    "-paths")  paths=$2;shift 2;log "found paths"
    ;;
    *) log "unknown parameter $1";shift 1;
    ;;
  esac

  if [[ -z "$1" ]];
  then 
    break; 
  fi
done

lunsSplit=(${luns//#/ })
namesSplit=(${names//#/ })
pathsSplit=(${paths//#/ })

lunsCount=${#lunsSplit[@]}
namesCount=${#namesSplit[@]}
pathsCount=${#pathsSplit[@]}

log "count $lunsCount $namesCount $pathsCount"

if [[ $lunsCount -eq $namesCount && $namesCount -eq $pathsCount ]]
then
  for ((ipart=0; ipart<lunsCount; ipart++))
  do
    lun=${lunsSplit[$ipart]}
    name=${namesSplit[$ipart]}
    path=${pathsSplit[$ipart]}

    log "creating disk with $lun $name $path"
    createlvm $lun "vg-$name" "lv-$name" "$path";
  done
else
  log "count not equal"
fi

exit