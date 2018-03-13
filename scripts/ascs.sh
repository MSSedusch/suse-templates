#!/bin/bash

function log()
{
  message=$@
  echo "$message"
  echo "$message" >> /var/log/sapconfigcreate
}

log "installing packages"
zypper update -y
zypper install -y -l sle-ha-release fence-agents