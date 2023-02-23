#!/bin/bash

# Set the process ID and cgroup name
PID=<your_process_id>
CGROUP_NAME=<your_cgroup_name>

# Set the network interface to monitor
NETWORK_INTERFACE=eth0

# Set the class ID to use for the cgroup
CLASS_ID=1:10

# Create the cgroup and assign the process to it
sudo cgcreate -g net_cls:$CLASS_ID
sudo cgclassify -g net_cls:$CLASS_ID $PID

# Set up the qdisc and class for the cgroup
sudo tc qdisc add dev $NETWORK_INTERFACE root handle 1: htb default 10
sudo tc class add dev $NETWORK_INTERFACE parent 1: classid $CLASS_ID net_cls matchall

# Mark packets from the cgroup with the appropriate class ID
sudo iptables -A OUTPUT -m cgroup --cgroup $CLASS_ID -j CLASSIFY --set-class $CLASS_ID

# Wait for five minutes
sleep 300

# Get the total bytes sent by the process since the last check
BYTES_SENT=$(sudo tc -s class show dev $NETWORK_INTERFACE classid $CLASS_ID | grep "bytes sent" | awk '{print $3}')

# Convert bytes to megabytes
MEGABYTES_SENT=$(echo "scale=2; $BYTES_SENT / (1024 * 1024)" | bc)

# Get the date and time
DATE=$(date +"%Y-%m-%d %H:%M:%S")

# Write the result to a log file
echo "$DATE: $MEGABYTES_SENT MB" >> ~/bandwidth.log

# Repeat the process every five minutes until the end of the day
while [[ $(date +"%H:%M") < "23:55" ]]; do
    sleep 300
    BYTES_SENT=$(sudo tc -s class show dev $NETWORK_INTERFACE classid $CLASS_ID | grep "bytes sent" | awk '{print $3}')
    MEGABYTES_SENT=$(echo "scale=2; $BYTES_SENT / (1024 * 1024)" | bc)
    DATE=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$DATE: $MEGABYTES_SENT MB" >> ~/bandwidth.log
done

# Generate a daily report
cat ~/bandwidth.log | grep "$(date +"%Y-%m-%d")" > ~/bandwidth_daily_report.log
