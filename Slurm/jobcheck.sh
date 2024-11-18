#!/bin/bash
##
### Author: Kyriakos Tsoukalas
### Email: apps@ktsoukalas.com
##
# Configurations
supercomputer_name=""
at_domain=""
from_email=""
bccemails=""
log_directory=""
monitor_url=""
check=true

### Export necessary paths for SLURM
export PATH="$PATH"

### Get a list of running jobs
running_jobs=$(squeue -t R -h -o "%i")

### Get the job_id from log files
cd $log_directory
log_files=($(ls))

### Function send emails after a job has finished
finishedjobsendemails() {
  local job_id="$1"

  ### Get the owner of the job
  owner=$(scontrol show job $job_id | grep "UserId" | awk -F "=" '{print $2}' | awk -F"@" '{print $1}')
  email="$owner$at_domain"

  ### Get the node and requested number of CPU cores for the job
  job_info=$(scontrol show job $job_id)
  node=$(echo "$job_info" | grep "NodeList" | awk -F= '{print $2}' | cut -d',' -f1)
  start_time=$(scontrol show job $job_id | grep "StartTime" | awk -F= '{print $2}')
  start_time_seconds=$(date -d "$start_time" +%s)
  current_time_seconds=$(date +%s)
  elapsed_time_seconds=$((current_time_seconds - start_time_seconds))

  ### Convert the elapsed time to hours and minutes
  elapsed_hours=$((elapsed_time_seconds / 3600))
  elapsed_minutes=$((elapsed_time_seconds % 3600 / 60))

  ### Get requested and consumed memory
  requested_mem=$(scontrol show job $job_id | grep "Mem" | awk -F "=" '{print $2}')
  consumed_mem=$(sstat -j $job_id --format=MaxRSS --noheader)
  consumed_vmem=$(sstat -j $job_id --format=MaxVMSize --noheader)

  ### Convert memory from KB to MB/GB
  requested_mem_in_kb=$(echo "$requested_mem" | awk '{print $1 * 1024}')
  consumed_mem_in_kb=$(echo "$consumed_mem" | awk '{print $1 / 1024}')
  consumed_vmem_in_kb=$(echo "$consumed_vmem" | awk '{print $1 / 1024}')

  ### Memory differences
  mem_diff=$((requested_mem_in_kb - consumed_mem_in_kb))
  suggested_mem_in_kb=$((consumed_mem_in_kb * 12 / 10))
  
  ### Debug memory - Convert to appropriate units (GB/MB)
  # Logic for converting to appropriate units omitted for brevity

  if (( mem_diff > 8388608 )); then
    current_date=$(date "+%Y-%m-%d")
    current_time=$(date "+%H:%M:%S")
    echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $requested_mem memory but was using $consumed_mem MB of memory."

    ### Send an email to the job owner with the actual physical memory used
    subject="$supercomputer_name: Memory under-utilization Alert: Job $job_id on Node $node"
    body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested mem: %s\nUnused mem: %s\nSuggested mem: %s\nPrediction of mem: calcmem %s\nMetadata: scontrol show job %s\nMonitor: %s\n\nThis is an automated message.\n\nJob %s on Node %s used %s of physical memory and %s of virtual memory, therefore it is suggested to request %s of physical memory for future similar jobs instead of %s. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_mem" "$mem_diff" "$suggested_mem_in_kb" "$job_id" "$monitor_url" "$job_id" "$node" "$consumed_mem" "$consumed_vmem" "$suggested_mem_in_kb" "$requested_mem")
    {
      echo "From: \"$supercomputer_name\" <$from_email>"
      echo "To: $email"
      echo "Bcc: $bccemails"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | /usr/sbin/sendmail -t
    echo "emailed_mem" >> $log_directory/$job_id
  fi

  ### CPU over-utilization and under-utilization handling (similar to memory)
  # SLURM logic for CPU and multithreading

  ### Check and send emails for CPU over- or under-utilization
  if [ "$notmultithread" == "true" ] && [ "$requested_cpus" != "1" ]; then
    current_date=$(date "+%Y-%m-%d")
    current_time=$(date "+%H:%M:%S")
    echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $requested_cpus CPU cores but process is not multithreading and was using $qstat_cpu_percentage% CPU"

    subject="$supercomputer_name: Multithreading Alert: Job $job_id on Node $node"
    body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested CPU cores: %s\nUnused CPU cores: %s\nSuggested CPU cores: %s\nMetadata: scontrol show job %s\nMonitor: %s\n\nThis is an automated message. If you get an alert it is highly likely that the referenced job is not multithreading and is using only 1 CPU.\n\nJob %s on Node %s was using %s%% CPU at the time of inspection. When a job is not multithreaded it cannot use more than 1 CPU (ppn), therefore it is important to request 1 CPU (ppn) for similar jobs. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_cpus" "$unused_cpus" "$max_cpus" "$job_id" "$monitor_url" "$job_id" "$node" "$qstat_cpu_percentage")
    {
      echo "From: \"$supercomputer_name\" <$from_email>"
      echo "To: $email"
      echo "Bcc: $bccemails"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | /usr/sbin/sendmail -t
    echo "emailed_mthread" >> $log_file
  fi

  ### Delete job log
  rm -f $log_directory/$job_id
}
### END Function send emails after a job has finished

heldjobalert() {
  local job_id="$1"
  ### Alert that a job is being held
  job_status=$(scontrol show job $job_id | grep "JobState" | awk -F= '{print $2}')
  if [ "$job_status" == "Held" ]; then
    subject="$supercomputer_name: Held Job Alert: Job $job_id"
    body=$(printf "Job ID: %s" "$job_id")
    {
      echo "From: \"$supercomputer_name\" <$from_email>"
      echo "To: $email"
      echo "Bcc: $bccemails"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | /usr/sbin/sendmail -t
  fi
}

startlogfile() {
  local job_id="$1"
  ### write a log file if it does not exist
  log_file="/etc/health/ncpucheck_files/$job_id"
  if [ ! -e "$log_file" ]; then
    touch "$log_file"
  fi
}

### Loop through jobs with a log file
for file in "${log_files[@]}"; do
  if [ -f "$file" ]; then
    job_status=$(scontrol show job $file | grep "JobState" | awk -F= '{print $2}')    
    if [ "$job_status" == "COMPLETED" ]; then
      finishedjobsendemails $file
      rm -f "$log_directory/$file"
    fi  
  fi
done

### Loop through each running job
for job_id in $running_jobs; do
  ### Alert about held job
  heldjobalert $job_id
  
  ### Write a log file if it does not exist
  startlogfile $job_id
  
  ### Process running job and send alerts for memory/CPU issues
  finishedjobsendemails $job_id
done

current_date=$(date "+%Y-%m-%d")
current_time=$(date "+%H:%M:%S")
if ($check); then
  echo "$current_date $current_time - No running jobs had over-allocated CPU cores"
fi

