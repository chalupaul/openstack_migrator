#!/bin/bash
helparg=${1:-h}
if [ $helparg == '-h' -o $helparg == '--help' -o $# -ne 2 ]; then
    echo "Usage: $0 <instance uuid> <new host name>"
    exit 0
fi
instance_uuid=$1
target_host=$2

# for the osx
export CLICOLOR=1
function einfo {
    green='\033[0;32m'
    nocolor='\033[0m'
    echo -e "${green}$1${nocolor}"
}
function ewarn {
    red='\033[0;31m'
    nocolor='\033[0m'
    echo -e "${red}$1${nocolor}"
}

# Need to be able to run nova commands
if [ `env | grep OS_USERNAME | wc -l` -eq 0 ]; then
    ewarn "Please source openrc before running."
    exit 1
fi

# Got to be root to manipulate files on the remote side
if [ `whoami` != 'root' ]; then
    ewarn "You must be root to run this script."
    exit 1
fi

# Check if the instance uuid exists
if [ `nova list | grep $instance_uuid | wc -l` -ne 1 ]; then
    ewarn "Cannot locate the instance uuid within this cluster."
    exit 1
fi

# Check if the host exists
if [ `nova-manage host list | grep $target_host | wc -l` -ne 1 ]; then
    ewarn "Cannot find a host by that name in this cluster."
    exit 1
fi

instance_virsh_name=`nova show $instance_uuid | grep 'OS-EXT-SRV-ATTR:instance_name' | awk '{print $4}'`
source_host=`nova show $instance_uuid | grep OS-EXT-SRV-ATTR:host | awk '{print $4}'`

# Make sure i'm not being told to do something silly
if [ $source_host == $target_host ]; then
    ewarn "Source and target hosts are the same."
    exit 1
fi

einfo "Attempting to shut down $instance_uuid on $source_host..."
nova stop $instance_uuid

shutoff=30
while [ $shutoff -gt 0 ]; do
    if [ `ssh -q $source_host "virsh list" | grep $instance_virsh_name | wc -l` -eq 0 ]; then
	shutoff=true
	break
    fi
    let shutoff=(shutoff - 1)
    sleep 1
done

if [ $shutoff != true ]; then
    ewarn "Failed to shut down $instance_virsh_name on $source_host."
    exit 1
fi


einfo "Rsyncing instance data from $source_host to $target_host..."
# If the version of nova-compute is different on the target,
# the necessary permissions will be different.
# So we try and find the right permissions. When in doubt, nova:nova
# Yes, if the directory we're looking at happenes to be broken, this will break also :(
if [ `ssh -q $target_host "ls -d /var/lib/nova/instances/*-*-*" | wc -l` -gt 0 ]; then
    set_all_nova=false
    declare -A permies
    working_dir=`ssh -q $target_host "ls -d /var/lib/nova/instances/*-*-* 2>/dev/null | head -1"`
    for i in `ssh -q $target_host "ls -la $working_dir" | grep -vP '^total' | grep -vP '\.\.$' | awk '{print $NF"::"$3":"$4}'`; do
	# The sed for './_dot_/g' is because '.' makes bash thing this is math heh
	key=`echo $i | sed 's/\./_dot_/g' | sed 's/::/ /' | awk '{print $1}'`
	val=`echo $i | sed 's/\./_dot_/g' | sed 's/::/ /' | awk '{print $2}'`
	permies[$key]=$val
    done
else
    set_all_nova=true
fi

# now rsync the files
ssh -q $source_host "rsync -rapP /var/lib/nova/instances/$instance_uuid $target_host:/var/lib/nova/instances"

# fix permissions now
working_dir="/var/lib/nova/instances/$instance_uuid"
if [ $set_all_nova == true ]; then
    einfo "Chowning new instance files to nova:nova..."
    ssh -q $target_host "chown -R nova:nova $working_dir"
else
    einfo "Fixing permissions on target side..."
    for i in `ssh -q $target_host "ls -la $working_dir" | grep -vP '^total' | grep -vP '\.\.$' | awk '{print $NF}'`; do
	key=`echo $i | sed 's/\./_dot_/g'`
	ssh -q $target_host "chown ${permies[$key]} $working_dir/$i"
    done
fi


einfo "Stopping monit and nova-compute services on $source_host..."
service_name=`ssh -q $source_host "ls /etc/init.d/*nova-compute" | sed 's/\// /g' | awk '{print $NF}'`
ssh -q $source_host "service monit stop"
# Monit hangs around for a few seconds
sleep 10
ssh -q $source_host "service $service_name stop"
sleep 5
ssh -q $source_host "killall nova-compute"


einfo "Waiting up to 2 minutes to make sure that the controller detects nova-compute is down..."
shutoff=30
while [ $shutoff -gt 0 ]; do
    if [ `nova-manage service list | grep $source_host | grep -P '^nova-compute' | awk '{print $5}'` != ':-)' ]; then
	shutoff=true
	break
    fi
    let shutoff=(shutoff - 1)
    sleep 5
done

if [ $shutoff != true ]; then
    ewarn "It appears that nova-compute did not stop on $source_host. Please help me!"
    exit 1
fi

einfo "Evacuating instance to $target_host. Hold on to your butts..."
nova evacuate --on-shared-storage $instance_uuid $target_host
# This sleep is necessary so that all the network stuff is ready
sleep 15
nova start $instance_uuid


ssh -q $source_host "service monit start"
ssh -q $source_host "service $service_name start"
einfo "Starting nova-compute and monit again. Make sure you check out that instance to see if it works!"
einfo "If everything works, run this command:"
einfo "ssh $source_host \"rm -rf /var/lib/instances/$instance_uuid\""
