#!/bin/bash

# Define the network interface to monitor
NETWORK_INTERFACE="p2p1"
INTERFACE_SPEED=10000000000 # 10 Gbps

# Define the list of process names to monitor
PROCESS_NAMES=("dcache" "css")

# Initialize flag variable to indicate if any processes were found
found_process=false

# Check if the network interface exists
ip link show $NETWORK_INTERFACE >/dev/null 2>&1 || { echo >&2 "Error: Network interface $NETWORK_INTERFACE does not exist. Aborting."; exit 1; }

# Loop through each process name and set up tc and net_cls rules
for process_name in "${PROCESS_NAMES[@]}"
do
  # Get the PID of the process
  pid=$(pgrep $process_name)

  if [ -n "$pid" ]; then
    found_process=true

    # Generate a unique CLASS_ID for the process
    CLASS_ID="$(uuidgen)"

    # Set up tc qdisc and class for the process
    sudo tc qdisc add dev $NETWORK_INTERFACE root handle 1: htb default 12
    sudo tc class add dev $NETWORK_INTERFACE parent 1: classid 1:$CLASS_ID htb rate ${INTERFACE_SPEED}bps
    sudo tc filter add dev $NETWORK_INTERFACE parent 1: prio 2 protocol ip handle $CLASS_ID fw classid 1:$CLASS_ID

    # Set up net_cls cgroup for the process
    sudo cgcreate -g net_cls:$CLASS_ID
    sudo cgset -r net_cls.classid=$CLASS_ID $CLASS_ID

    # Assign the process and all its child processes to the net_cls cgroup
    for child_pid in $(pstree -p $pid | grep -o "([0-9]\+)" | grep -o "[0-9]\+")
    do
      sudo cgclassify -g net_cls:$CLASS_ID $child_pid
    done
  else
    echo "Process $process_name not found"
  fi
done

# If >= 1 process available, wait for 5 minutes
if [ "$found_process" = false ]; then
  echo "No ${PROCESS_NAMES[@]} found. Exiting script."
  exit 1
else
    sleep 300
fi

# Generate a daily report of the total bandwidth sent by each process
for process_name in "${PROCESS_NAMES[@]}"
do
  # Get the PID of the process
  pid=$(pgrep $process_name)

  if [ -n "$pid" ]; then
    # Generate the file name for the daily report
    report_file="bandwidth_daily_report_$process_name.log"

    # Get the total number of bytes transmitted by the process
    BYTES_SENT="$(sudo tc -s -d class show dev $NETWORK_INTERFACE classid 1:$CLASS_ID | awk '/bytes/ {print $2}')"

    # Log the total number of bytes to the daily report file
    echo "$(date +%Y-%m-%d_%H:%M:%S) Process $process_name sent $BYTES_SENT bytes" >> "$report_file"
  else
    echo "Process $process_name not found"
  fi
done

# Reset the tc and net_cls settings for this session on exit
sudo tc qdisc del dev $NETWORK_INTERFACE root
sudo cgdelete net_cls:/