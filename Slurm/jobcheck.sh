#!/usr/bin/env bash 
##
### Author: Kyriakos Tsoukalas
### Email: apps@ktsoukalas.com
##
# Configurations
# Enable strict mode for safety
set -euo pipefail
umask 027
supercomuter_name="Supercomputer"
at_domain="@example.edu"
from_email="rcd$at_domain"
bccemails="rcd$at_domain"
log_directory=""
# Central log file for jobcheck events
LOG=""
check=true
PROTECTED_PARTITIONS=("apps" "debug")
unusedCPUemail=30
unusedCPUcancel=70
noCPUscancel=4
unusedMEMemail=50
# unusedMEMcancel in GB
unusedMEMcancel=64
memSuggest=130
DRY_RUN=true

# Usage information
usage() {
  echo "Usage: $0 [-h] [-d]"
  echo "  -h    Show this help message"
  echo "  -d    Dry-run mode (do not actually cancel jobs)"
  exit 0
}

# Parse command-line options
while getopts ":hd" opt; do
  case $opt in
    h) usage ;;
    d) DRY_RUN=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND -1))

mkdir -p $log_directory

### Keep a sensible PATH for SLURM commands
export PATH="$PATH"

### CPU Utilization of requested resources
cpu_utilization() {
    local jid=$(get_real_job_id "$1")
    #echo $jid
    local cpu elapsed cpus

    cpu=$(sstat -j "${jid}.batch" -nP -o AveCPU 2>/dev/null) || return 1
    elapsed=$(squeue -j "$jid" -h -o %M 2>/dev/null) || return 1
    cpus=$(scontrol show job "$jid" 2>/dev/null |
        sed -n 's/.*NumCPUs=\([^ ]*\).*/\1/p')

    [[ -n "$cpu" && -n "$elapsed" && -n "$cpus" ]] || return 1

    awk -v cpu="$cpu" -v elapsed="$elapsed" -v cpus="$cpus" '
    function sec(t) {
        split(t,a,":")
        if (a[1] ~ /-/) {
            split(a[1],d,"-")
            return d[1]*86400 + d[2]*3600 + a[2]*60 + a[3]
        }
        return a[1]*3600 + a[2]*60 + a[3]
    }
    BEGIN {
        printf "%.1f\n", sec(cpu) / sec(elapsed) / cpus * 100
    }'
}

### Convert a SLURM memory string (e.g. 16G, 4096Mc, 1024K) to kilobytes.
### Prints "<kb> <per_cpu_flag>" (per_cpu_flag is 0 if the request was per CPU).
mem_to_kb() {
  local mem="${1:-0}"
  awk -v mem="$mem" 'BEGIN {
    gsub(/[[:space:]]/,"",mem)
    if (mem=="" || mem=="0") {printf "0 1\n"; exit}
    per=1
    if (mem ~ /[cC]/) {per=0; gsub(/[cC]/,"",mem)}
    num=mem
    gsub(/[A-Za-z]+$/,"",num)
    sfx=mem
    gsub(/^[0-9.]+/,"",sfx)
    if (num=="") {printf "0 1\n"; exit}
    mult=1
    sfx=toupper(sfx)
    if (sfx ~ /^M/) mult=1024
    else if (sfx ~ /^G/) mult=1024*1024
    else if (sfx ~ /^T/) mult=1024*1024*1024
    kb=num*mult
    printf "%d %d\n", kb+0, per
  }'
}

### Convert a SLURM time string ([DD-]HH:MM:SS[.frac]) to seconds.
time_to_seconds() {
  local t="${1:-0}"
  awk -v t="$t" 'BEGIN {
    if (t=="" || t=="UNLIMITED" || t=="INVALID" || t=="Unknown") {print 0; exit}
    days=0
    if (match(t,/^[0-9]+-/)) {
      days=substr(t,1,RLENGTH-1)+0
      t=substr(t,RLENGTH+1)
    }
    sub(/\..*$/,"",t)
    n=split(t,p,":")
    h=0; m=0; s=0
    if (n>=3) {h=p[1]+0; m=p[2]+0; s=p[3]+0}
    else if (n==2) {m=p[1]+0; s=p[2]+0}
    else if (n==1) {s=p[1]+0}
    print days*86400 + h*3600 + m*60 + s
  }'
}

### Format a value in kilobytes to a human readable value/unit pair.
format_mem() {
  local kb="${1:-0}"
  if (( kb > 10000000 )); then
    echo "$((kb/1024/1024)) gb"
  elif (( kb > 10000 )); then
    echo "$((kb/1024)) mb"
  else
    echo "$kb kb"
  fi
}

# Helper: floating point less-than comparison
float_lt() {
  local a=$1 b=$2
  (( $(echo "$a < $b" | bc -l) ))
}

# Helper: floating point greater-or-equal comparison
float_ge() {
  local a=$1 b=$2
  (( $(echo "$a >= $b" | bc -l) ))
}

# Centralized email sending function
send_email() {
  local to="$1" subject="$2" body="$3"
  {
    echo "From: \"$supercomuter_name\" "
    echo "To: $to"
    #echo "Bcc: $bccemails"
    echo "Subject: $subject"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo ""
    echo "$body"
  } | /usr/sbin/sendmail -t
}

### Compute average CPU utilisation for a running job from sstat.
### Prints "<cpu_percent> <allocated_cpus> <elapsed_seconds>".
get_running_cpu_pct() {

# Compute average CPU utilisation for a running job from sstat.
# Prints "<cpu_percent> <allocated_cpus> <elapsed_seconds>".

  local job_id="$1"

  local stat elapsed alloc avecpu
  # Determine the correct sstat identifier:
#   * Normal jobs have a hidden ".batch" step.
#   * Array elements already include the element suffix (e.g. 12345_7) and do NOT have a .batch step.
if [[ "$job_id" == *_* ]]; then
    sstat_id="$job_id"
else
    sstat_id="${job_id}.batch"
fi
stat=$(sstat -j "$sstat_id" \
      --format=AveCPU,NTasks \
      -n -P 2>/dev/null)

  [[ -z "$stat" ]] && { echo "0 0 0"; return; }

  IFS='|' read -r avecpu ntasks <<< "$stat"

  # Get elapsed time and allocated CPUs from squeue (fallback if needed)
  elapsed=$(squeue -h -j "$job_id" -o "%M" | head -n 1)
  alloc=$(squeue -h -j "$job_id" -o "%C" | head -n 1)

  # If squeue did not provide allocated CPUs, fall back to NTasks from sstat
  if [[ -z "$alloc" || "$alloc" == "0" ]]; then
    alloc="$ntasks"
  fi

  local cpu_s elapsed_s cpu_percent

  # Convert average CPU time (in format HH:MM:SS) to seconds
  cpu_s=$(time_to_seconds "$avecpu")
  elapsed_s=$(time_to_seconds "$elapsed")

  if [[ "$elapsed_s" -gt 0 && "$alloc" -gt 0 ]]; then
    cpu_percent=$(echo "scale=2; $cpu_s * 100 / ($elapsed_s * $alloc)" | bc -l)
  else
    cpu_percent=0
  fi

  echo "$cpu_percent $alloc $elapsed_s"
}

# Compute average CPU utilisation for any job (running or finished).
# Returns "<cpu_percent> <allocated_cpus> <elapsed_seconds>".
get_job_cpu_pct() {
  local job_id="$1"
  # Determine if job is still running
  if squeue -h -j "$job_id" > /dev/null 2>&1; then
    get_running_cpu_pct "$job_id"
    return
  fi
  # Use sacct for completed jobs
  local sacct_out=$(sacct -j "$job_id" --format=Elapsed,TotalCPU,AllocCPUS -n -P 2>/dev/null)
  [[ -z "$sacct_out" ]] && { echo "0 0 0"; return; }
  local elapsed totalcpu alloc
  IFS='|' read -r elapsed totalcpu alloc <<< "$sacct_out"
  local elapsed_s=$(time_to_seconds "$elapsed")
  local totalcpu_s=$(time_to_seconds "$totalcpu")
  local cpu_percent=0
  if [[ $elapsed_s -gt 0 && $alloc -gt 0 ]]; then
    cpu_percent=$(echo "scale=2; $totalcpu_s * 100 / ($elapsed_s * $alloc)" | bc -l)
  fi
  echo "$cpu_percent $alloc $elapsed_s"
}

### Get real job ID from steps/arrays
get_real_job_id() {
    local input_job="$1"
    local real_id

    real_id=$(squeue -h -j "$input_job" -o "%A" 2>/dev/null)

    if [[ -n "$real_id" ]]; then
        echo "$real_id"
    else
        echo "$input_job"
    fi
}

### Return "<avg_rss_KB> <avg_vsize_KB>"
# New version – returns average RSS and VSize across all steps.
get_running_mem() {
    local job_id="$1"
    local max_rss_kb=0 max_vmem_kb=0

    # Use the appropriate step identifier for array jobs as well.
if [[ "$job_id" == *_* ]]; then
    mem_sstat_id="$job_id"
else
    mem_sstat_id="${job_id}.batch"
fi
sstat -j "$mem_sstat_id" \
          --format=AveRSS,AveVMSize \
          -n -P 2>/dev/null |
        while IFS='|' read -r rss vmem; do
            # Guard against empty/N/A fields:
            [[ -z "$rss" || "$rss" == N/A ]] && rss="0"
            [[ -z "$vmem" || "$vmem" == N/A ]] && vmem="0"

            read rss_kb _   < <(mem_to_kb "$rss")
            read vmem_kb _ < <(mem_to_kb "$vmem")

            (( rss_kb > max_rss_kb ))   && max_rss_kb=$rss_kb
            (( vmem_kb > max_vmem_kb )) && max_vmem_kb=$vmem_kb
        done

    echo "${max_rss_kb:-0} ${max_vmem_kb:-0}"
}

### Send emails after a job has finished
finishedjobsendemails() {
  local job_id="$1"
  local out
  out=$(sacct -j "$job_id" --format=User,NodeList,Elapsed,TotalCPU,AllocCPUS,ReqMem,AveRSS,AveVMSize,State -n -P 2>/dev/null)
  if [[ -z "$out" ]]; then
    rm -f "$log_directory/$job_id"
    return
  fi

  local user="" nodelist="" elapsed="00:00:00" reqmem="" maxrss_str="0" maxvm_str="0" maxrss_kb=0 maxvm_kb=0 state=""
  local alloc=1 total_cpu_s=0
  while IFS='|' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9; do
    # Skip if no fields at all
    [[ -z "$f1" && -z "$f2" && -z "$f3" ]] && continue

    # Check if this is a parent job (has user in f1) vs batch step (empty user, has other fields)
    if [[ -n "$f1" ]] && [[ "$f1" != *.* ]]; then
      # Parent job line
      user="$f1"
      nodelist="$f2"
      elapsed="$f3"
      reqmem="$f6"
      state="$f9"
    elif [[ -n "$f2" || -n "$f3" || -n "$f7" ]]; then
      # Batch/step line (may have empty user but has other fields)
      local cpu_s
      cpu_s=$(time_to_seconds "$f4")
      total_cpu_s=$((total_cpu_s + cpu_s))
      [[ -n "$f5" && "$f5" != "0" ]] && alloc="$f5"
      # Capture memory from batch step (f7 is AveRSS)
      if [[ -n "$f7" ]]; then
        # Convert to KB and keep the maximum; update the display string only when this step is the new max
        rss_kb=$(mem_to_kb "$f7" | awk '{print $1}')
        if (( rss_kb > maxrss_kb )); then
          maxrss_kb=$rss_kb
          maxrss_str="$f7"
        fi
      fi
      if [[ -n "$f8" ]]; then
        vmem_kb=$(mem_to_kb "$f8" | awk '{print $1}')
        if (( vmem_kb > maxvm_kb )); then
          maxvm_kb=$vmem_kb
          maxvm_str="$f8"
        fi
      fi
    fi
  done <<< "$out"

  # Fallback: For array jobs, explicitly query the batch step if memory data is missing
  if [[ -z "$maxrss_str" || "$maxrss_str" == "0" ]]; then
    local batch_mem=$(sacct -j "${job_id}.batch" --format=AveRSS -n -P 2>/dev/null | head -n1)
    if [[ -n "$batch_mem" && "$batch_mem" != "0" ]]; then
      maxrss_str="$batch_mem"
      rss_kb=$(mem_to_kb "$batch_mem" | awk '{print $1}')
      (( rss_kb > maxrss_kb )) && maxrss_kb=$rss_kb
    fi
  fi

  [[ -z "$user" ]] && { rm -f "$log_directory/$job_id"; return; }

  local owner="$user"
  local email="$owner$at_domain"
  local node="$nodelist"
  local requested_cpus="$alloc"
  # Get partition for the job (used for apps‑specific alerts)
  local partition=$(sacct -j "$job_id" --format=Partition -n -P 2>/dev/null | head -n1)

  local elapsed_s elapsed_hours elapsed_minutes
  # If the parent job line has no elapsed (common for array jobs), fetch the longest elapsed from any step
  if [[ -z "$elapsed" || "$elapsed" == "00:00:00" ]]; then
    # Determine the maximum elapsed time (in seconds) among all steps
    max_elapsed_sec=0
    max_elapsed_str="00:00:00"
    while IFS= read -r line; do
      sec=$(time_to_seconds "$line")
      if (( sec > max_elapsed_sec )); then
        max_elapsed_sec=$sec
        max_elapsed_str=$line
      fi
    done < <(sacct -j "$job_id" --format=Elapsed -n -P)
    elapsed="$max_elapsed_str"
  fi
  elapsed_s=$(time_to_seconds "$elapsed")
  elapsed_hours=$((elapsed_s / 3600))
  elapsed_minutes=$(((elapsed_s % 3600) / 60))

  ### Get requested and consumed memory
  local get_requested_mem="$reqmem"
  local get_consumed_mem="$maxrss_str"
  local get_consumed_vmem="$maxvm_str"

  local requested_mem_in_kb per_cpu
  read requested_mem_in_kb per_cpu < <(mem_to_kb "$get_requested_mem")
  if [[ $per_cpu -eq 0 ]]; then
    requested_mem_in_kb=$((requested_mem_in_kb * alloc))
  fi

  local consumed_mem_in_kb consumed_vmem_in_kb
  read consumed_mem_in_kb _ < <(mem_to_kb "$get_consumed_mem")
  read consumed_vmem_in_kb _ < <(mem_to_kb "$get_consumed_vmem")

  # Calculate memory utilization percentage
  local mem_util_percent=100
  if [[ $requested_mem_in_kb -gt 0 ]]; then
    mem_util_percent=$(echo "scale=2; $consumed_mem_in_kb * 100 / $requested_mem_in_kb" | bc -l)
  fi

  local mem_diff=$((requested_mem_in_kb - consumed_mem_in_kb))
  local suggested_mem_in_kb=$((consumed_mem_in_kb * memSuggest / 100))
  local eight_gb_in_kb=8388608
  local four_gb_in_kb=4194304

  if (( suggested_mem_in_kb - consumed_mem_in_kb > eight_gb_in_kb )); then
    suggested_mem_in_kb=$((consumed_mem_in_kb + four_gb_in_kb))
  fi

  read show_requested_mem show_requested_mem_unit < <(format_mem "$requested_mem_in_kb")
  read show_consumed_mem show_consumed_mem_unit < <(format_mem "$consumed_mem_in_kb")
  read show_consumed_vmem show_consumed_vmem_unit < <(format_mem "$consumed_vmem_in_kb")
  read show_mem_diff show_mem_diff_unit < <(format_mem "$mem_diff")
  read show_suggested_mem show_suggested_mem_unit < <(format_mem "$suggested_mem_in_kb")

  # Send alert if memory utilization is less than unusedMEMemail threshold
  # and the unused memory is at least 8 GB
  unused_mem_kb=$((requested_mem_in_kb - consumed_mem_in_kb))
  unused_mem_gb=$(echo "scale=2; $unused_mem_kb / (1024*1024)" | bc -l)
  if (( $(echo "$mem_util_percent < $unusedMEMemail" | bc -l) )) && (( $(echo "$unused_mem_gb >= 8" | bc -l) )); then
    local current_date current_time
    current_date=$(date "+%Y-%m-%d")
    current_time=$(date "+%H:%M:%S")
    echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $get_requested_mem of memory but was using $show_consumed_mem$show_consumed_mem_unit (${mem_util_percent}%)."

    local subject body
    subject="$supercomuter_name: Memory under-utilization Alert: Job $job_id on Node $node"
    body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested mem: %s\nMax used mem: %s (%.1f%%)\nUnused mem: %s\nSuggested mem: %s\nAverage Requested mem Utilization: %.1f%%\n\nThis is an automated message.\n\nJob %s on Node %s used a maximum of %s of physical memory (%.1f%% utilization). Memory utilization was below expected levels. Consider requesting %s of physical memory for future similar jobs instead of %s. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$get_requested_mem" "$show_consumed_mem$show_consumed_mem_unit" "$mem_util_percent" "$show_mem_diff$show_mem_diff_unit" "$show_suggested_mem$show_suggested_mem_unit" "$mem_util_percent" "$job_id" "$node" "$show_consumed_mem$show_consumed_mem_unit" "$mem_util_percent" "$show_suggested_mem$show_suggested_mem_unit" "$get_requested_mem")
    {
      echo "From: \"$supercomuter_name\" <$from_email>"
      echo "To: $email"
      #echo "Bcc: $bccemails"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | /usr/sbin/sendmail -t
    echo "emailed_mem" >> "$log_directory/$job_id"
  fi

  ### CPU utilisation from sacct
  local cpu_percent=0
  if [[ $elapsed_s -gt 0 && $alloc -gt 0 ]]; then
    cpu_percent=$(echo "scale=2; $total_cpu_s * 100 / ($elapsed_s * $alloc)" | bc -l)
  fi

  # Estimate used CPUs based on average CPU utilization
  used_cpus=$(echo "scale=2; $cpu_percent * $alloc / 100" | bc -l)
  # Round to nearest integer
  max_cpus=$(printf "%.0f" "$used_cpus")
  # Ensure at least 1 CPU
  if (( max_cpus < 1 )); then max_cpus=1; fi
  local unused_cpus=$(echo "$requested_cpus - $max_cpus" | bc)
  # Calculate percent of unused CPUs for threshold comparison
  local percent_unused_cpus=0
  if (( requested_cpus > 0 )); then
    percent_unused_cpus=$(echo "scale=2; $unused_cpus * 100 / $requested_cpus" | bc -l)
  fi

  local current_date current_time
  current_date=$(date "+%Y-%m-%d")
  current_time=$(date "+%H:%M:%S")

  ### CPU over-utilization
  if (( $(echo "$unused_cpus < -1" | bc -l) )); then
    echo "$current_date $current_time - Job $job_id" >> $LOG
    #echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $requested_cpus CPU cores but was using $cpu_percent% CPU"

    local subject body
    subject="$supercomuter_name: CPU over-utilization Alert: Job $job_id on Node $node"
    body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested CPU cores: %s\nUnused CPU cores: %s\nSuggested CPU cores: %s\nAverage Requested CPU Utilization: %s%%\n\nThis is an automated message.\n\nJob %s on Node %s used an average of %s%% CPU, therefore it is suggested to request %s CPU cores for future similar jobs instead of %s. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_cpus" "$unused_cpus" "$max_cpus" "$cpu_percent" "$job_id" "$node" "$cpu_percent" "$max_cpus" "$requested_cpus")
    {
      echo "From: \"$supercomuter_name\" <$from_email>"
      echo "To: $email"
      #echo "Bcc: $bccemails"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | /usr/sbin/sendmail -t
    echo "emailed_addcpu" >> "$log_directory/$job_id"
  fi

  ### CPU under-utilization
  ### CPU under-utilization (all partitions)
  if (( $(echo "$percent_unused_cpus >= $unusedCPUemail" | bc -l) )); then
      echo "$current_date $current_time - Job $job_id" >> $LOG
      echo "$current_date $current_time - Job $job_id on Node $node, owned by $owner, requested $requested_cpus CPU cores but used $cpu_percent% CPU"

      local subject body
      subject="$supercomuter_name: CPU under-utilization Alert: Job $job_id on Node $node"
      body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested CPU cores: %s\nUnused CPU cores: %s\nSuggested CPU cores: %s\nAverage Requested CPU Utilization: %s%%\n\nThis is an automated message.\n\nJob %s on Node %s used %s%% CPU, therefore it is suggested to request %s CPU cores for future similar jobs instead of %s. Please review job %s." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_cpus" "$unused_cpus" "$max_cpus" "$cpu_percent" "$job_id" "$node" "$cpu_percent" "$max_cpus" "$requested_cpus" "$job_id")
      {
        echo "From: \"$supercomuter_name\" <$from_email>"
        echo "To: $email"
        #echo "Bcc: $bccemails"
        echo "Subject: $subject"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        echo "$body"
      } | /usr/sbin/sendmail -t
      echo "emailed_addcpu" >> "$log_directory/$job_id"
  fi

  ### Delete job log
  rm -f "$log_directory/$job_id"
}

heldjobalert() {
  local job_id="$1"
  local job_status job_reason owner email
  job_status=$(squeue -h -j "$job_id" -o "%T" 2>/dev/null)
  job_reason=$(squeue -h -j "$job_id" -o "%R" 2>/dev/null)
  if [[ "$job_status" == "PENDING" && "$job_reason" == Held* ]]; then
    owner=$(squeue -h -j "$job_id" -o "%u")
    email="$owner$at_domain"
    local subject body
    subject="$supercomuter_name: Held Job Alert: Job $job_id"
    body=$(printf "Job ID: %s" "$job_id")
    {
      echo "From: \"$supercomuter_name\" <$from_email>"
      echo "To: $email"
      #echo "Bcc: $bccemails"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo ""
      echo "$body"
    } | /usr/sbin/sendmail -t
  fi
}

cannotrunalert() {
  local job_id="$1"
  local job_status job_reason owner email
  local submit_time job_timelimit req_cpus req_mem partition

  job_status=$(squeue -h -j "$job_id" -o "%T" 2>/dev/null)
  job_reason=$(squeue -h -j "$job_id" -o "%R" 2>/dev/null)
  submit_time=$(squeue -h -j "$job_id" -o "%r" 2>/dev/null)
  req_cpus=$(squeue -h -j "$job_id" -o "%c" 2>/dev/null)
  req_mem=$(squeue -h -j "$job_id" -o "%m" 2>/dev/null)
  partition=$(squeue -h -j "$job_id" -o "%P" 2>/dev/null)
  job_timelimit=$(squeue -h -j "$job_id" -o "%l" 2>/dev/null)

  # Check if job is held and has been pending for > 24 hours
  if [[ "$job_status" == "PENDING" && "$job_reason" == Held* ]]; then
    if [[ -n "$submit_time" ]]; then
      submit_epoch=$(date -d "$submit_time" +%s 2>/dev/null)
      current_epoch=$(date +%s)
      hold_duration=$((current_epoch - submit_epoch))

      # If held > 24 hours (86400 seconds)
      if (( hold_duration > 86400 )); then
        owner=$(squeue -h -j "$job_id" -o "%u")
        email="$owner$at_domain"
        local subject body
        local current_date current_time
        current_date=$(date "+%Y-%m-%d")
        current_time=$(date "+%H:%M:%S")

        # Get available partitions with their limits
        local available_partitions
        available_partitions=$(sinfo -h -o "%P %c %m" 2>/dev/null | grep -v "^*" | head -3)

        subject="$supercomuter_name: Job Cannot Run - Requested Resources Not Available"
        body=$(printf "Job ID: %s\nPartition: %s\nOwner: %s\nSubmit Time: %s\nHeld for: %d hours\n\nRequested Resources:\n  CPUs: %s\n  Memory: %s\n  Time Limit: %s\n\nReason: %s\n\nThis job has been held for over 24 hours and requested resources may not be available in the %s partition. Consider submitting with reduced resource requirements or to a different partition.\n\nAvailable Partitions (sample):\n%s\n\nPlease review and either modify your job request or contact support if you believe this is an error." "$job_id" "$partition" "$owner" "$submit_time" "$((hold_duration / 3600))" "$req_cpus" "$req_mem" "$job_timelimit" "$job_reason" "$partition" "$available_partitions")
        {
          echo "From: \"$supercomuter_name\" <$from_email>"
          echo "To: $email"
          #echo "Bcc: $bccemails"
          echo "Subject: $subject"
          echo "Content-Type: text/plain; charset=UTF-8"
          echo ""
          echo "$body"
        } | /usr/sbin/sendmail -t
        echo "$current_date $current_time - Job $job_id held > 24 hours, cannot-run alert sent"
      fi
    fi
  fi
}

startlogfile() {
  local job_id="$1"
  local log_file="$log_directory/$job_id"
  if [ ! -e "$log_file" ]; then
    touch "$log_file"
  fi
}

### Get a list of running jobs
running_jobs=$(squeue -t R -h -o "%i")

### Loop through jobs with a log file
cd "$log_directory" || { echo "Cannot access log directory $log_directory"; exit 1; }
for file in *; do
  if [ -f "$file" ]; then
    job_status=$(sacct -j "$file" --format=State -n -P 2>/dev/null | head -1)
    if [[ -n "$job_status" && "$job_status" != "RUNNING" && "$job_status" != "PENDING" && "$job_status" != "SUSPENDED" && "$job_status" != "COMPLETING" ]]; then
      finishedjobsendemails "$file"
      #####rm -f "$log_directory/$file"
    fi
  fi
done

### Loop through each running job
for display_job_id in $running_jobs; do
  ### Find real job ID
  job_id=$(get_real_job_id "$display_job_id")
  ### Alert about held job
  heldjobalert "$job_id"

  ### Alert about jobs that cannot run (held > 24 hours)
  cannotrunalert "$job_id"

  ### Write a log/checkcount file if it does not exist
  startlogfile "$job_id"

  log_file="$log_directory/$job_id"

  ### Get owner, node, start time and requested CPUs from squeue
  jobinfo=$(squeue -h -j "$job_id" -o "%u|%N|%S|%C|%P")
  IFS='|' read -r owner node start_time requested_cpus partition <<< "$jobinfo"
  [[ -z "$owner" ]] && continue
  email="$owner$at_domain"

  util=$(cpu_utilization "$job_id") || {
    echo "Failed to get CPU utilization for job $job_id" >&2
    exit 1
  }

  ### Elapsed time since start
  if [[ -z "$start_time" || "$start_time" == "Unknown" || "$start_time" == "N/A" ]]; then
    start_time_seconds=0
  else
    start_time_seconds=$(date -d "$start_time" +%s 2>/dev/null || echo 0)
  fi
  [[ "$start_time_seconds" -eq 0 ]] && continue
  current_time_seconds=$(date +%s)
  elapsed_time_seconds=$((current_time_seconds - start_time_seconds))

  ### Convert the elapsed time to hours and minutes
  elapsed_hours=$((elapsed_time_seconds / 3600))
  elapsed_minutes=$(((elapsed_time_seconds % 3600) / 60))
  elapsed_total_minutes=$((elapsed_time_seconds / 60))

  ### If the job has not run for at least 15 minutes, skip it
  if [ "$elapsed_time_seconds" -gt 900 ]; then
    log_file_line1=$(head -n 1 "$log_file")
    log_file_line2=$(head -n 2 "$log_file" | tail -n 1)
    log_file_line3=$(head -n 3 "$log_file" | tail -n 1)

    read cpu_percent allocated_cpus _ < <(get_running_cpu_pct "$job_id")
    if [[ -z "$requested_cpus" || "$requested_cpus" == "0" ]]; then
      requested_cpus=$allocated_cpus
    fi
    #echo "Job $job_id requested $requested_cpus and CPU utilization is ${util}%"

    ### Flag for multithreading
    # Estimate used CPUs based on average CPU utilization
    used_cpus=$(echo "scale=2; $cpu_percent * $requested_cpus / 100" | bc -l)
    # Round to nearest integer
    max_cpus=$(printf "%.0f" "$used_cpus")
    # Ensure at least 1 CPU
    if (( max_cpus < 1 )); then max_cpus=1; fi
    unused_cpus=$(echo "$requested_cpus - $max_cpus" | bc)


    current_date=$(date "+%Y-%m-%d")
    current_time=$(date "+%H:%M:%S")

    # Compute percentage of unused CPUs
    percent_unused=$(echo "scale=2; $unused_cpus * 100 / $requested_cpus" | bc -l)
    # Use the global unusedCPUcancel threshold for running job cancellation
    threshold=$unusedCPUcancel
    if (( $(echo "$percent_unused >= $threshold" | bc -l) )); then
      checkcount_file="$log_file"
      ### Read the first line of the checkcount_file
      if [ -f "$checkcount_file" ]; then
        job_check=$(head -n 1 "$checkcount_file" | tr -cd '0-9')
        job_check=$((10#${job_check:-0} + 1))
      else
        job_check=1
      fi
      echo "$job_check" > "$checkcount_file"

      ### Check if the first line is equal to 3
      if [ "$job_check" -eq 3 ]; then
      if [[ ! " ${PROTECTED_PARTITIONS[@]} " =~ " ${partition} " ]]; then
        # Protect small jobs (1-4 CPUs) from cancellation, similar to memory-based guard
        if (( requested_cpus > noCPUscancel )); then
          echo "$current_date $current_time - DELETED job $job_id on Node $node, owned by $owner, requested $requested_cpus CPU cores but was using $cpu_percent% CPU"
          logger -t jobcheck_slurm "Deleted job $job_id on node $node (owner $owner) due to $percent_unused% unused CPUs"
          if ! $DRY_RUN; then
            scancel "$job_id"
            subject="$supercomuter_name: CPU under-utilization Alert: Job $job_id on Node $node would have been stopped"
          else
            subject="$supercomuter_name: CPU under-utilization Alert: Job $job_id on Node $node was stopped"
          fi
        fi

        ### Send an email to the job owner that job was stopped
        #subject="$supercomuter_name: CPU under-utilization Alert: Job $job_id on Node $node was stopped"
        body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested CPU cores: %s\nUnused CPU cores: %s\nSuggested CPU cores: %s\nAverage Requested CPU Utilization: %s%%\n\nThis is an automated message.\n\nJob %s on Node %s was using an average of %s%% CPU after %s minutes and was stopped. It is suggested to request %s CPU cores for future similar jobs instead of %s. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$requested_cpus" "$unused_cpus" "$max_cpus" "$cpu_percent" "$job_id" "$node" "$cpu_percent" "$elapsed_total_minutes" "$max_cpus" "$requested_cpus")
        {
          echo "From: \"$supercomuter_name\" <$from_email>"
          echo "To: $email"
          #echo "Bcc: $bccemails"
          echo "Subject: $subject"
          echo "Content-Type: text/plain; charset=UTF-8"
          echo ""
          echo "$body"
        } | /usr/sbin/sendmail -t
        rm -f "$checkcount_file"
        rm -f "$log_file"
        # ---- Memory under‑utilization cancellation check ----
        # Compute unused memory in GB
        unused_mem_kb=$((requested_mem_in_kb - consumed_mem_in_kb))
        unused_mem_gb=$(echo "scale=2; $unused_mem_kb / (1024*1024)" | bc -l)
        mem_cancel_threshold=$unusedMEMcancel   # GB
        if (( $(echo "$unused_mem_gb >= $mem_cancel_threshold" | bc -l) )); then
          mem_check_file="${log_file}_mem"
          if [ -f "$mem_check_file" ]; then
            mem_check=$(head -n1 "$mem_check_file" | tr -cd '0-9')
            mem_check=$((10#${mem_check:-0} + 1))
          else
            mem_check=1
          fi
          echo "$mem_check" > "$mem_check_file"
          if [ "$mem_check" -eq 3 ]; then
            if [[ ! " ${PROTECTED_PARTITIONS[@]} " =~ " ${partition} " ]]; then
              if (( requested_cpus > noCPUscancel )); then
                echo "$current_date $current_time - DELETED job $job_id on Node $node, owned by $owner, requested $get_requested_mem memory but only used $show_consumed_mem$show_consumed_mem_unit"
                logger -t jobcheck_slurm "Deleted job $job_id on node $node (owner $owner) due to $unused_mem_gb GB unused memory"
                if ! $DRY_RUN; then
                  scancel "$job_id"
                  subject="$supercomuter_name: Memory under‑utilization Alert: Job $job_id on Node $node would have been stopped"
                else
                  subject="$supercomuter_name: Memory under‑utilization Alert: Job $job_id on Node $node was stopped"
                fi
                # Send memory‑under‑utilization email
                if (( $(echo "$unused_mem_gb >= 8" | bc -l) )); then
                  #subject="$supercomuter_name: Memory under‑utilization Alert: Job $job_id on Node $node was stopped"
                  body=$(printf "Job ID: %s\nNode: %s\nOwner: %s\nElapsed Time: %sh%sm\nRequested mem: %s\nUnused mem: %sGB\nSuggested mem: %s\nAverage Requested mem Utilization: %.1f%%\n\nThis is an automated message.\n\nJob %s on Node %s used only %s of physical memory (%.1f%% utilization). Memory utilization was below expected levels. Consider requesting %s of physical memory for future similar jobs instead of %s. Please review your job." "$job_id" "$node" "$owner" "$elapsed_hours" "$elapsed_minutes" "$get_requested_mem" "$unused_mem_gb" "$show_suggested_mem$show_suggested_mem_unit" "$mem_util_percent" "$job_id" "$node" "$show_consumed_mem$show_consumed_mem_unit" "$mem_util_percent" "$show_suggested_mem$show_suggested_mem_unit" "$get_requested_mem")
                  {
                    echo "From: \"$supercomuter_name\" "
                    echo "To: $email"
                    #echo "Bcc: $bccemails"
                    echo "Subject: $subject"
                    echo "Content-Type: text/plain; charset=UTF-8"
                    echo ""
                    echo "$body"
                  } | /usr/sbin/sendmail -t
                fi
                rm -f "$mem_check_file"
                rm -f "$log_file"
            fi
          else
            echo "$mem_check" > "$mem_check_file"
          fi
        fi
        fi
      fi
      else
        echo "$job_check" > "$checkcount_file"
      fi
    elif false; then # DISABLED: other alert
      # This block is disabled
      true
    fi
  fi
done

current_date=$(date "+%Y-%m-%d")
current_time=$(date "+%H:%M:%S")
if [[ $check == true ]]; then
  echo "$current_date $current_time - Run"
fi
