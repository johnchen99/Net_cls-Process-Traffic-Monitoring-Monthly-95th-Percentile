#!/bin/bash

NETWORK_INTERFACE="p2p1"
PROCESS_NAMES=("dcache" "css")
# INTERFACE_SPEED=10000000000 # 10 Gbps
INTERFACE_SPEED=1000000000 # 1 Gbps
DIR="/root/bandwidth_calc_netcls"
DAILY_DIR="${DIR}/daily"
MONTHLY_DIR="${DIR}/monthly"
INTERVAL=300
PERCENTILE=95

# Check if process exists, else remove from list 
process_to_remove=()
# Loop through the list of processes
for i in "${!PROCESS_NAMES[@]}"
do
  # Get the PID of the process
  pid=$(pgrep "${PROCESS_NAMES[$i]}")
  # Check if the process is running by sending signal 0
  if [ -z "$pid" ]; then
    # If the process is not running, mark it for removal
    process_to_remove+=("$i")
  fi
done
# Remove marked processes from the list
for i in "${process_to_remove[@]}"
do
  unset PROCESS_NAMES[$i]
done
# Reset array indices
PROCESS_NAMES=("${PROCESS_NAMES[@]}")

# Generate unique CLASS_ID for all the process
declare -a CLASS_IDS
for name in "${PROCESS_NAMES[@]}"; do
  class_id=$(uuidgen)
  CLASS_IDS+=("$class_id")
done

# Check all three files exist, create them if needed
check_directories() {
  local directories=("$@")

  for dir in "${directories[@]}"
  do
    if [ ! -d "$dir" ]; then
      mkdir -p "$dir"
    fi
  done
}
check_directories "$DIR" "$DAILY_DIR" "$MONTHLY_DIR"


found_process=false


# Check if the network interface exists, else exit
ip link show $NETWORK_INTERFACE >/dev/null 2>&1 || { echo >&2 "Error: Network interface $NETWORK_INTERFACE does not exist. Aborting."; exit 1; }

# Loop through each process name and set up tc and net_cls rules
for i in "${!PROCESS_NAMES[@]}"
do
  # Get the PID of the process
  pid=$(pgrep $PROCESS_NAMES[$i])

  if [ -n "$pid" ]; then
    found_process=true

    # Set up tc qdisc 
    sudo tc qdisc add dev $NETWORK_INTERFACE root handle 1:$i htb default 12
    sudo tc class add dev $NETWORK_INTERFACE parent 1:$i classid 1:${CLASS_IDS[$i]} htb rate ${INTERFACE_SPEED}bps
    sudo tc filter add dev $NETWORK_INTERFACE parent 1:$i prio 2 protocol ip handle ${CLASS_IDS[$i]} fw classid 1:${CLASS_IDS[$i]}

    # Set up net_cls cgroup
    sudo cgcreate -g net_cls:${CLASS_IDS[$i]}
    sudo cgset -r net_cls.classid=${CLASS_IDS[$i]} ${CLASS_IDS[$i]}

    # Assign the process and all its child processes to the net_cls cgroup
    for child_pid in $(pstree -p $pid | grep -o "([0-9]\+)" | grep -o "[0-9]\+")
    do
      sudo cgclassify -g net_cls:${CLASS_IDS[$i]} $child_pid
    done
  fi
done

# If >= 1 process available, wait for 5 minutes, else exit
if [ "$found_process" = false ]; then
  echo "No process ${PROCESS_NAMES[@]} found. Exiting script."
  exit 1
else
    sleep $INTERVAL
fi

# Generate a daily report of the total bandwidth sent by each process
for process_name in "${PROCESS_NAMES[@]}"
do
  # Generate the file name for the daily report
  report_file="${DAILY_DIR}/$(date +%Y-%m-%d)_${process_name}.log"

  # Get the total number of bytes transmitted by the process
  BYTES_SENT="$(sudo tc -s -d class show dev $NETWORK_INTERFACE classid 1:$CLASS_ID | awk '/bytes/ {print $2}')"

  # Log the total number of bytes to the daily report file
  echo "$(date +%Y-%m-%d_%H:%M:%S),$BYTES_SENT" >> "$report_file"
done

# Reset the tc and net_cls settings for this session on exit
for i in "${!PROCESS_NAMES[@]}"
do
  sudo tc qdisc del dev $NETWORK_INTERFACE root handle 1:$i
  sudo cgdelete -g net_cls:${CLASS_IDS[$i]}
done

# Monthly 95th percentile 
if [ "$(date +%d)" -eq 1 ]; then
  for i in "${!PROCESS_NAMES[@]}"
  do
    # Generate the file name for the monthly report if file not exist
    report_file="${MONTHLY_DIR}/$(date -d "last month" +%Y-%m)_${PROCESS_NAMES[$i]}_95th.log"
    if [ ! -f "$report_file" ]; then
      
      # Create an array to store the daily bandwidth usage values for this process
      total_usage=()

      # Loop through all the daily log files from the previous month for this process
      for daily_file in "${DAILY_DIR}/$(date -d "last month" +%Y-%m)-*-${PROCESS_NAMES[$i]}.log"
      do
        # Extract the total number of bytes transmitted from the daily log file
        bytes_sent=$(awk '{ sum += $2 } END { print sum }' "$daily_file")
        
        # Add the value to the usage array
        total_usage+=("$bytes_sent")
      done

      # Sort the array 
      sorted_usage=($(printf '%s\n' "${total_usage[@]}" | sort -n))

      # Calculate the 95th percentile value
      index=$(((${#sorted_arr[@]}*95+${PERCENTILE})/100-1))
      percentile=${sorted_usage[$index]}

      # Write the monthly report to the file
      echo "$(date +%Y-%m-%d_%H:%M:%S),$(date -d "last month" +%Y-%m),${PROCESS_NAMES[$i]},$percentile" >> "$report_file"
    fi
  done
fi