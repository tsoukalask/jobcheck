#!/bin/bash
##
### Author: Kyriakos Tsoukalas
### Email: apps@ktsoukalas.com
##
# Configurations
supercomuter_name="Supercomputer"
at_domain="@example.edu"
from_email="rcd$at_domain"
bccemails="rcd$at_domain"
log_directory=""
docs_url=""
check=true
mail_agent="mailx" # mailx or sendmail
allow_userlist=("")

### Export necessary paths
export PATH="/sbin:/bin:/usr/sbin:/usr/bin:/opt/pbs/bin:/opt/pbs/sbin:$PATH"

### Get a list of running jobs
running_jobs=$(qstat -n | grep " R " | awk '{print $1}')

### Get the job_id from log files
cd $log_directory
log_files=($(ls))

### Function allow user in list
user_in_list() {
    local user="$1"
    shift
    for u; do
        [[ "$u" == "$user" ]] && return 0
    done
    return 1
}

### Function emailer
send_email() {
  local mail_agent="$1"
  local supercomuter_name="$2"
  local from_email="$3"
  local email="$4"
  local bccemails="$5"
  local subject="$6"
  local body="$7"

  if [ "$mail_agent" = "sendmail" ]; then
    {
      echo "From: \"$supercomuter_name\" <$from_email>"
      echo "To: $email"
      echo "Bcc: $bccemails"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | /usr/sbin/sendmail -f "$supercomuter_name <$from_email>" -t
  elif [ "$mail_agent" = "mailx" ]; then
    echo "$body" | mail -r "$from_email ($supercomuter_name)" -s "$subject" "$email"
    echo "$body" | mail -r "$from_email ($supercomuter_name)" -s "$subject" "$bccemails"
  else
    echo "Unsupported mail agent: $mail_agent"
  fi
}

### Function send emails after a job has finished
finishedjobsendemails() {
  local job_id="$1"

  ### [PBS Pro] Get the owner of the job
  owner=$(qstat -xf $job_id | grep "Job_Owner" | awk -F" = " '{print $2}' | awk -F"@" '{print $1}')
  job_queue=$(qstat -xf $job_id | grep "queue = " | awk -F" = " '{print $2}')
  email="$owner$at_domain"

  ### [PBS Pro] Get used walltime
  used_walltime=$(qstat -xf "$1" | awk '/resources_used.walltime/ {print $3}')
  used_walltime=$(echo "$used_walltime" | xargs)
  uwhours="${used_walltime%%:*}"
  uwremaining="${used_walltime#*:}"
  uwminutes="${uwremaining%%:*}"
  uwseconds="${uwremaining#*:}"
  uwhours=$((10#$uwhours))
  uwminutes=$((10#$uwminutes))
  uwseconds=$((10#$uwseconds))
  used_walltime_total_minutes=$((uwhours * 60 + uwminutes + uwseconds / 60))

  ### [PBS Pro] Get the node and requested number of CPU cores (TSK column) for the job
  job_info=$(qstat -xf $job_id | grep "exec_host")
  node=$(echo $job_info | awk '{split($0,a,"= "); split(a[2],b,"/"); print b[1]}')
  start_time=$(qstat -xf $job_id | grep stime | awk -F "= " '/stime/ {print $2}')
  start_time_seconds=$(date -d "$start_time" +%s)
  current_time_seconds=$(date +%s)
  elapsed_time_seconds=$((current_time_seconds - start_time_seconds))

  ### Convert the elapsed time to hours and minutes
  elapsed_hours=$((elapsed_time_seconds / 3600))
  elapsed_minutes=$((elapsed_time_seconds % 3600 / 60))

  ### Get requested and consumed memory
  get_requested_mem=$(qstat -xf $job_id | grep "Resource_List.mem" | awk '{print $3}')
  get_consumed_mem=$(qstat -xf $job_id | grep "resources_used.mem" | awk '{print $3}')
  get_consumed_vmem=$(qstat -xf $job_id | grep "resources_used.vmem" | awk '{print $3}')

  ### Split memory into value and suffix
  mem_value=${get_requested_mem%[kmg]b}
  mem_suffix=${get_requested_mem:${#mem_value}}

  if [[ $mem_suffix == "kb" ]]; then
    requested_mem_in_kb=$mem_value
  elif [[ $mem_suffix == "mb" ]]; then
    requested_mem_in_kb=$((mem_value * 1024))
  elif [[ $mem_suffix == "gb" ]]; then
    requested_mem_in_kb=$((mem_value * 1024 * 1024))
  else
    requested_mem_in_kb=1
  fi

  ### [PBS Pro] Consumed memory is reported in kb
  consumed_mem_in_kb="${get_consumed_mem%kb}"
  consumed_vmem_in_kb="${get_consumed_vmem%kb}"
  mem_diff=$((requested_mem_in_kb - consumed_mem_in_kb))
  suggested_mem_in_kb=$((consumed_mem_in_kb * 12 / 10))
  eight_gb_in_kb=8388608
  four_gb_in_kb=4194304

  if (( suggested_mem_in_kb - consumed_mem_in_kb > eight_gb_in_kb )); then
    suggested_mem_in_kb=$((consumed_mem_in_kb + four_gb_in_kb))
  fi

  show_requested_mem_unit="kb"
  show_consumed_mem_unit="kb"
  show_consumed_vmem_unit="kb"
  show_mem_diff_unit="kb"
  show_suggested_mem_unit="kb"

  if [ $requested_mem_in_kb -gt 10000000 ]; then
    show_requested_mem=$((requested_mem_in_kb / 1024 / 1024))
    show_requested_mem_unit="gb"
  elif [ $requested_mem_in_kb -gt 10000 ]; then
    show_requested_mem=$((requested_mem_in_kb / 1024))
    show_requested_mem_unit="mb"
  fi

  if [ $consumed_mem_in_kb -gt 10000000 ]; then
    show_consumed_mem=$((consumed_mem_in_kb / 1024 / 1024))
    show_consumed_mem_unit="gb"
  elif [ $consumed_mem_in_kb -gt 10000 ]; then
    show_consumed_mem=$((consumed_mem_in_kb / 1024))
    show_consumed_mem_unit="mb"
  else
    show_consumed_mem=$consumed_mem_in_kb
  fi

  if [ $consumed_vmem_in_kb -gt 10000000 ]; then
    show_consumed_vmem=$((consumed_vmem_in_kb / 1024 / 1024))
    show_consumed_vmem_unit="gb"
  elif [ $consumed_vmem_in_kb -gt 10000 ]; then
    show_consumed_vmem=$((consumed_vmem_in_kb / 1024))
    show_consumed_vmem_unit="mb"
  else
    show_consumed_vmem=$consumed_vmem_in_kb
  fi

  if [ $mem_diff -gt 10000000 ]; then
    show_mem_diff=$((mem_diff / 1024 / 1024))
    show_mem_diff_unit="gb"
  elif [ $mem_diff -gt 10000 ]; then
    show_mem_diff=$((mem_diff / 1024))
    show_mem_diff_unit="mb"
  else
    show_mem_diff=$mem_diff
  fi

  if [ $suggested_mem_in_kb -gt 10000000 ]; then
    show_suggested_mem=$((suggested_mem_in_kb / 1024 / 1024))
    show_suggested_mem_unit="gb"
  elif [ $suggested_mem_in_kb -gt 10000 ]; then
    show_suggested_mem=$((suggested_mem_in_kb / 1024))
    show_suggested_mem_unit="mb"
  else
    show_suggested_mem=$suggested_mem_in_kb
  fi

  if (( mem_diff > 8388608 )) && [ "$job_queue" != "apps" ] && (( used_walltime_total_minutes > 13 )); then
    ### Get current date and time
    current_date=$(date "+%Y-%m-%d")
    current_time=$(date "+%H:%M:%S")
    echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $get_requested_mem of memory but was using $show_consumed_mem$show_consumed_mem_unit of memory."

    ### Send an email to the job owner with the actual physical memory used
    subject="$supercomuter_name: Memory under-utilization Alert: Job $job_id on Node $node"
    body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested mem: %s\nUnused mem: %s\nSuggested mem: %s\nPrediction of mem: calcmem %s\nMetadata: qstat -xf %s\n\nThis is an automated message.\n\nJob %s on Node %s used %s of physical memory and %s of virtual memory (swap), therefore it is suggested to request %s of physical memory for future similar jobs instead of %s. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$get_requested_mem" "$show_mem_diff$show_mem_diff_unit" "$show_suggested_mem$show_suggested_mem_unit" "$job_id" "$job_id" "$job_id" "$node" "$show_consumed_mem$show_consumed_mem_unit" "$show_consumed_vmem$show_consumed_vmem_unit" "$show_suggested_mem$show_suggested_mem_unit" "$get_requested_mem")
    send_email "$mail_agent" "$supercomuter_name" "$from_email" "$email" "$bccemails" "$subject" "$body"
    echo "emailed_mem" >> $log_directory/$job_id
  fi

  ### [PBS Pro] Flag for multiprocessing
  notmultiprocessing=false
  requested_cpus_percentage=$(echo $job_info | awk -F= '{split($NF, a, "/|\\*"); print a[3] / 32 * 100 }')
  requested_resources=$(qstat -xf $job_id | grep "Resource_List.select" | awk '{print $3}')
  requested_nodes="${requested_resources%%:*}"
  requested_node_cpus="${requested_resources#*:ncpus=}"
  requested_node_cpus="${requested_node_cpus%%:*}"
  requested_cpus=$((requested_node_cpus * requested_nodes))

  qstat_cpu_percentage=$(qstat -xf $job_id | grep "resources_used.cpupercent" | awk '{print $3}')
  max_cpus1=$(echo "scale=0; $qstat_cpu_percentage / 100" | bc -l)

  if [ "$max_cpus1" -eq "0" ]; then
    max_cpus1=1
    notmultiprocessing=true
  fi

  if (( $(echo "$qstat_cpu_percentage > $max_cpus1 * 110" | bc -l) )); then
    max_cpus=$((max_cpus1 + 1))
  else
    max_cpus=$max_cpus1
  fi

  if [ "$max_cpus" -eq 0 ]; then
    max_cpus=1
  fi
  unused_cpus=$(echo "$requested_cpus - $max_cpus" | bc)

  ### EMAILS
  current_date=$(date "+%Y-%m-%d")
  current_time=$(date "+%H:%M:%S")

  ### CPU over-utilization
  if (( $(echo "$unused_cpus < -1" | bc -l) )) && (( used_walltime_total_minutes > 13 )); then
      echo "$current_date $current_time - Job $job_id" >> /etc/health/debuglog
      echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $requested_cpus CPU cores but was using $qstat_cpu_percentage% CPU"

      ### Send an email to the owner of the job with the actual number of CPU cores being used
      subject="$supercomuter_name: CPU over-utilization Alert: Job $job_id on Node $node"
      body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested CPU cores: %s\nUnused CPU cores: %s\nSuggested CPU cores: %s\nPrediction of CPU cores: calcppn %s\nMetadata: qstat -xf %s\n\nThis is an automated message.\n\nJob %s on Node %s used an average of %s%% CPU, therefore it is suggested to request %s CPU cores (ppn) for future similar jobs instead of %s. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_cpus" "$unused_cpus" "$max_cpus" "$job_id" "$job_id" "$job_id" "$node" "$qstat_cpu_percentage" "$max_cpus" "$requested_cpus")
      send_email "$mail_agent" "$supercomuter_name" "$from_email" "$email" "$bccemails" "$subject" "$body"
      echo "emailed_addcpu" >> $log_directory/$job_id
  fi

  ### CPU under-utilization
  if [ $(echo "$unused_cpus > 1" | bc -l) -eq 1 ] && [ "$job_queue" != "apps" ] && (( used_walltime_total_minutes > 13 )); then
  #if (( $(echo "$unused_cpus > 1" | bc -l) )); then 
    echo "$current_date $current_time - Job $job_id" >> /etc/health/debuglog
    echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $requested_cpus CPU cores but used $qstat_cpu_percentage% CPU"

    ### Send an email to the owner of the job with the actual number of CPU cores being used
    subject="$supercomuter_name: CPU under-utilization Alert: Job $job_id on Node $node"
    body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested CPU cores: %s\nUnused CPU cores: %s\nSuggested CPU cores: %s\nPrediction of CPU cores: calcppn %s\nMetadata: qstat -xf %s\n\nThis is an automated message.\n\nJob %s on Node %s used %s%% CPU, therefore it is suggested to request %s CPU cores (ppn) for future similar jobs instead of %s. Please review job %s." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_cpus" "$unused_cpus" "$max_cpus" "$job_id" "$job_id" "$job_id" "$node" "$qstat_cpu_percentage" "$max_cpus" "$requested_cpus" "$job_id")
    send_email "$mail_agent" "$supercomuter_name" "$from_email" "$email" "$bccemails" "$subject" "$body"
    echo "emailed_addcpu" >> $log_directory/$job_id
  fi

  ### Delete job log
  rm -f $log_directory/$job_id
}
### END Function send emails after a job has finished

heldjobalert() {
  local job_id="$1"
  ### [PBS Pro] Alert that a job that is being held
  job_status=$(qstat -xf "$job_id" | awk '/job_state/ {print $3}')
  if [ $job_status == "H" ]; then
    subject="$supercomuter_name: Held Job Alert: Job $job_id"
    body=$(printf "Job ID: %s" "$job_id")
    send_email "$mail_agent" "$supercomuter_name" "$from_email" "$email" "$bccemails" "$subject" "$body"
    ### [PBS Pro] Automatic release
    #qrls $job_id
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
    job_status=$(qstat -xf "$file" | awk '/job_state/ {print $3}')
    if [ "$job_status" == "F" ]; then
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

  ### Get the owner of the job
  owner=$(qstat -xf $job_id | grep "Job_Owner" | awk -F" = " '{print $2}' | awk -F"@" '{print $1}')
  job_queue=$(qstat -xf $job_id | grep "queue = " | awk -F" = " '{print $2}')
  job_excl=$(qstat -xf $job_id | grep "Resource_List.nodes" | awk -F'#|=' '{print $4}')
  email="$owner@colgate.edu"

  ### Get the node and requested number of CPU cores (TSK column) for the job
  job_info=$(qstat -xf $job_id | grep "exec_host")
  node=$(echo $job_info | awk '{split($0,a,"= "); split(a[2],b,"/"); print b[1]}')
  start_time=$(qstat -xf $job_id | grep stime | awk -F "= " '/stime/ {print $2}')
  start_time_seconds=$(date -d "$start_time" +%s)
  current_time_seconds=$(date +%s)
  elapsed_time_seconds=$((current_time_seconds - start_time_seconds))

  ### Convert the elapsed time to hours and minutes
  elapsed_hours=$((elapsed_time_seconds / 3600))
  elapsed_minutes=$((elapsed_time_seconds % 3600 / 60))

  ### If the job has not run for at least 10 minutes, skip it
  if [ "$elapsed_time_seconds" -gt 900 ]; then
    log_file_line1=$(head -n 1 $log_file)
    log_file_line2=$(head -n 2 $log_file | tail -n 1)
    log_file_line3=$(head -n 3 $log_file | tail -n 1)

    ### Flag for multiprocessing
    notmultiprocessing=false
    requested_cpus_percentage=$(echo $job_info | awk -F= '{split($NF, a, "/|\\*"); print a[3] / 32 * 100 }')
    requested_resources=$(qstat -xf $job_id | grep "Resource_List.select" | awk '{print $3}')
    requested_nodes="${requested_resources%%:*}"
    requested_node_cpus="${requested_resources#*:ncpus=}"
    requested_node_cpus="${requested_node_cpus%%:*}"
    requested_cpus=$((requested_node_cpus * requested_nodes))

    qstat_cpu_percentage=$(qstat -xf $job_id | grep "resources_used.cpupercent" | awk '{print $3}')
    max_cpus1=$(echo "scale=0; $qstat_cpu_percentage / 100" | bc -l)
    if [ "$max_cpus1" -eq "0" ]; then
      max_cpus1=1
      notmultiprocessing=true
    fi
    if (( $(echo "$qstat_cpu_percentage > $max_cpus1 * 110" | bc -l) )); then
      max_cpus=$((max_cpus1 + 1))
    else
      max_cpus=$max_cpus1
    fi
    if [ "$max_cpus" -eq 0 ]; then
      max_cpus=1
    fi
    unused_cpus=$(echo "$requested_cpus - $max_cpus" | bc)

    if (( $(echo "$unused_cpus > 6" | bc -l) )); then
      checkcount_file="/etc/health/ncpucheck_files/$job_id"
      ### Read the first line of the checkcount_file
      if [ -f "$checkcount_file" ]; then
        read -r job_check < "$checkcount_file"
        job_check=$((job_check + 1))
      else
        echo "1" > $checkcount_file
        job_check="1"
      fi

      ### Check if the first line is equal to 3
      if [ "$job_check" -eq 3 ] && [ "$job_queue" != "apps" ] && [ "$job_excl" != "excl" ] && ! user_in_list "$owner" "${allow_userlist[@]}"; then
      #if [ "$job_check" -eq 3 ]; then
        echo "$current_date $current_time - DELETED job $job_id on Node $node, owned by $owner, requested $requested_cpus CPU cores but was using $qstat_cpu_percentage% CPU"
        qdel $job_id
        resubmission_result=$(/etc/health/scripts/resubmit2pbs $job_id $max_cpus)
              resubmission_result_processed=$(echo "$resubmission_result" | awk -F'\n' '{print $1}')
        resubmission_result_firstline=$(echo "$resubmission_result_processed" | head -n 1)
              if [[ $resubmission_result == *"Resubmission Failed"* ]]; then
          resubmit_result="but resubmission failed."
        else
          resubmit_result="and resubmitted with job ID $resubmission_result_firstline and ppn=$max_cpus."
              fi

        ### Send an email to the job owner that job was stopped and resubmission reattempted
        subject="$supercomuter_name: CPU under-utilization Alert: Job $job_id on Node $node was stopped"
        body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested CPU cores: %s\nUnused CPU cores: %s\nSuggested CPU cores: %s\nMetadata: qstat -xf %s\n\nThis is an automated message.\n\nJob %s on Node %s was using an average of %s%% CPU after %s minutes and was stopped $resubmit_result It is suggested to request %s CPU cores (ppn) for future similar jobs instead of %s. Please review both jobs.\n\nRead more at: %s" "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_cpus" "$unused_cpus" "$max_cpus" "$job_id" "$job_id" "$node" "$qstat_cpu_percentage" "$elapsed_minutes" "$max_cpus" "$requested_cpus" "$docs_url")
        send_email "$mail_agent" "$supercomuter_name" "$from_email" "$email" "$bccemails" "$subject" "$body"
        rm -f $checkcount_file
        rm -f $log_file
      else
        echo $job_check > $checkcount_file
      fi
    elif [ "$notmultiprocessing" == "true" ] && [ "$job_queue" != "apps" ] && [ "$requested_cpus" != "1" ] && [[ "$log_file_line1" != "emailed_mprocessing" ]] && [[ "$log_file_line2" != "emailed_mprocessing" ]] && [[ "$log_file_line3" != "emailed_mprocessing" ]]; then
      check=false
      ### Get current date and time
      current_date=$(date "+%Y-%m-%d")
      current_time=$(date "+%H:%M:%S")
      echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $requested_cpus CPU cores but process is not multiprocessing and was using $qstat_cpu_percentage% CPU"

      ### Send an email to the owner of the job with the actual number of CPU cores being used
      subject="$supercomuter_name: Multiprocessing Alert: Job $job_id on Node $node"
      body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested CPU cores: %s\nUnused CPU cores: %s\nSuggested CPU cores: %s\nMetadata: qstat -xf %s\n\nThis is an automated message. If you get an alert it is highly likely that the referenced job is not multiprocessing and is using only 1 CPU.\n\nJob %s on Node %s was using %s%% CPU at the time of inspection. When a job is not multiprocessing it cannot use more that 1 CPU (ppn), therefore it is important to request 1 CPU (ppn) for similar jobs. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_cpus" "$unused_cpus" "$max_cpus" "$job_id" "$job_id" "$node" "$qstat_cpu_percentage")
      send_email "$mail_agent" "$supercomuter_name" "$from_email" "$email" "$bccemails" "$subject" "$body"
      echo "emailed_mprocessing" >> $log_file
    fi
  fi
done

current_date=$(date "+%Y-%m-%d")
current_time=$(date "+%H:%M:%S")
if ($check); then
  echo "$current_date $current_time - No running jobs had over-allocated CPU cores"
fi

