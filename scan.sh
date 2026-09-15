#!/usr/bin/env bash

set -uo pipefail

username=""
target=""
port=22
identity=""
jump_host=""
ssh_config=""
timeout_seconds=3
concurrency=32
text_output_path=""
all_addresses=0
allow_large_range=0
interactive=0
detail_limit=54

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

show_help() {
  cat <<'EOF'
SSH Command Scanner

Required:
  --user USER                 SSH login name
  --target CIDR               IPv4 CIDR target, for example 192.168.1.0/24

SSH options:
  --port NUMBER               SSH port (default: 22)
  --identity PATH             Private key passed to ssh -i
  --jump-host HOST            Jump host passed to ssh -J
  --ssh-config PATH           Config file passed to ssh -F

Scan options:
  --timeout SECONDS           Connection timeout (default: 3)
  --concurrency NUMBER        Concurrent SSH processes (default: 32)
  --text-output PATH.txt      Save the ASCII table to a UTF-8 text file
  --all-addresses             Include IPv4 network and broadcast addresses
  --allow-large-range         Allow 1025-65536 target addresses
  --interactive               Prompt for missing required values
  -h, --help                  Show this help

By default, network and broadcast addresses are skipped for prefixes /0-/30.
Both addresses in /31 and the single address in /32 are always scanned.
EOF
}

require_value() {
  [[ $# -ge 2 && -n ${2-} ]] || die "$1 requires a value."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      require_value "$@"
      username=$2
      shift 2
      ;;
    --target)
      require_value "$@"
      target=$2
      shift 2
      ;;
    --port)
      require_value "$@"
      port=$2
      shift 2
      ;;
    --identity)
      require_value "$@"
      identity=$2
      shift 2
      ;;
    --jump-host)
      require_value "$@"
      jump_host=$2
      shift 2
      ;;
    --ssh-config)
      require_value "$@"
      ssh_config=$2
      shift 2
      ;;
    --timeout)
      require_value "$@"
      timeout_seconds=$2
      shift 2
      ;;
    --concurrency)
      require_value "$@"
      concurrency=$2
      shift 2
      ;;
    --text-output)
      require_value "$@"
      text_output_path=$2
      shift 2
      ;;
    --all-addresses)
      all_addresses=1
      shift
      ;;
    --allow-large-range)
      allow_large_range=1
      shift
      ;;
    --interactive)
      interactive=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

prompt_value() {
  local label=$1
  [[ -r /dev/tty ]] || die 'Interactive input is unavailable; pass --user and --target.'
  printf '%s' "$label" >/dev/tty
  IFS= read -r PROMPT_VALUE </dev/tty || die 'Unable to read interactive input.'
}

if (( interactive )); then
  if [[ -z $username ]]; then
    prompt_value 'SSH username: '
    username=$PROMPT_VALUE
  fi
  if [[ -z $target ]]; then
    prompt_value 'Target CIDR: '
    target=$PROMPT_VALUE
  fi
fi

if [[ -z $username || -z $target ]]; then
  show_help >&2
  die 'Both --user and --target are required; add --interactive to be prompted.'
fi
[[ $username != *[[:space:]]* && $username != *[$'\001'-$'\037'$'\177']* ]] || die 'user cannot contain whitespace or control characters.'
[[ -z $jump_host || ( $jump_host != *[[:space:]]* && $jump_host != *[$'\001'-$'\037'$'\177']* ) ]] || die 'jump-host cannot contain whitespace or control characters.'
for path_value in "$identity" "$ssh_config" "$text_output_path"; do
  [[ $path_value != *[$'\001'-$'\037'$'\177']* ]] || die 'path options cannot contain control characters.'
done

for numeric_value in "$port" "$timeout_seconds" "$concurrency"; do
  [[ $numeric_value =~ ^[0-9]+$ ]] || die 'port, timeout, and concurrency must be decimal integers.'
done
port=$((10#$port))
timeout_seconds=$((10#$timeout_seconds))
concurrency=$((10#$concurrency))
(( port >= 1 && port <= 65535 )) || die 'port must be between 1 and 65535.'
(( timeout_seconds >= 1 && timeout_seconds <= 60 )) || die 'timeout must be between 1 and 60.'
(( concurrency >= 1 && concurrency <= 128 )) || die 'concurrency must be between 1 and 128.'
command -v ssh >/dev/null 2>&1 || die 'OpenSSH client was not found in PATH.'

if [[ -n $text_output_path ]]; then
  output_name=${text_output_path##*/}
  if [[ $output_name != *.* ]]; then
    text_output_path=${text_output_path}.txt
  elif [[ $text_output_path != *.txt ]]; then
    die 'text-output must use the .txt extension.'
  fi

  output_directory=$(dirname "$text_output_path")
  [[ -d $output_directory ]] || die "Output directory does not exist: $output_directory"
fi

cidr_regex='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]|[12][0-9]|3[0-2])$'
[[ $target =~ $cidr_regex ]] || die 'target must be an IPv4 CIDR such as 192.168.1.0/24.'
first_octet=$((10#${BASH_REMATCH[1]}))
second_octet=$((10#${BASH_REMATCH[2]}))
third_octet=$((10#${BASH_REMATCH[3]}))
fourth_octet=$((10#${BASH_REMATCH[4]}))
prefix_length=$((10#${BASH_REMATCH[5]}))
(( first_octet <= 255 && second_octet <= 255 && third_octet <= 255 && fourth_octet <= 255 )) || die 'target contains an invalid IPv4 address.'

address_value=$(( (first_octet << 24) | (second_octet << 16) | (third_octet << 8) | fourth_octet ))
host_bits=$((32 - prefix_length))
block_size=$((1 << host_bits))
network_value=$((address_value - (address_value % block_size)))
broadcast_value=$((network_value + block_size - 1))

if (( ! all_addresses && prefix_length <= 30 )); then
  first_value=$((network_value + 1))
  last_value=$((broadcast_value - 1))
else
  first_value=$network_value
  last_value=$broadcast_value
fi
target_count=$((last_value - first_value + 1))

default_host_limit=1024
absolute_host_limit=65536
(( target_count <= absolute_host_limit )) || die "target contains ${target_count} addresses; the absolute limit is ${absolute_host_limit}."
if (( target_count > default_host_limit && ! allow_large_range )); then
  die "target contains ${target_count} addresses; the default limit is ${default_host_limit}. Add --allow-large-range after confirming scope."
fi

number_to_ip() {
  local value=$1
  printf '%s.%s.%s.%s' \
    "$(( (value >> 24) & 255 ))" \
    "$(( (value >> 16) & 255 ))" \
    "$(( (value >> 8) & 255 ))" \
    "$(( value & 255 ))"
}

canonical_target="$(number_to_ip "$network_value")/${prefix_length}"

now_ms() {
  local value
  value=$(date +%s%3N 2>/dev/null || true)
  if [[ $value =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '%s000' "$(date +%s)"
  fi
}

classify_result() {
  local exit_code=$1
  local detail=$2

  if (( exit_code == 0 )); then printf 'connected'; return; fi
  if [[ $detail == *'Permission denied'* ]]; then printf 'reachable_auth_failed'; return; fi
  if [[ $detail == *'Connection refused'* ]]; then printf 'refused'; return; fi
  if [[ $detail == *'REMOTE HOST IDENTIFICATION HAS CHANGED'* || $detail == *'Host key verification failed'* ]]; then printf 'host_key_failed'; return; fi
  if [[ $detail == *'timed out'* || $detail == *'No route to host'* || $detail == *'Network is unreachable'* || $detail == *'Connection closed'* ]]; then printf 'unreachable_or_timeout'; return; fi
  if [[ -z $detail ]]; then printf 'indeterminate'; return; fi
  printf 'other_error'
}

tmp_base=${TMPDIR:-/tmp}
tmp_base=${tmp_base%/}
temp_dir=$(mktemp -d "${tmp_base}/ssh-command-scanner.XXXXXX") || die 'Unable to create a temporary directory.'

cleanup() {
  case $temp_dir in
    "${tmp_base}"/ssh-command-scanner.*) rm -rf -- "$temp_dir" ;;
  esac
}
trap cleanup EXIT

ssh_arguments=(
  -o BatchMode=yes
  -o "ConnectTimeout=${timeout_seconds}"
  -o ConnectionAttempts=1
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -p "$port"
)
[[ -z $identity ]] || ssh_arguments+=(-i "$identity")
[[ -z $jump_host ]] || ssh_arguments+=(-J "$jump_host")
[[ -z $ssh_config ]] || ssh_arguments+=(-F "$ssh_config")

scan_one() {
  local address_value_to_scan=$1
  local address started finished duration output exit_code status detail full_detail result_file
  address=$(number_to_ip "$address_value_to_scan")

  started=$(now_ms)
  output=$(ssh "${ssh_arguments[@]}" -l "$username" "$address" exit 2>&1)
  exit_code=$?
  finished=$(now_ms)
  duration=$((finished - started))

  full_detail=${output//$'\r'/ }
  full_detail=${full_detail//$'\n'/ }
  full_detail=${full_detail//$'\t'/ }
  full_detail=${full_detail//|//}
  status=$(classify_result "$exit_code" "$full_detail")
  detail=$full_detail
  if ((${#detail} > detail_limit)); then
    detail=${detail:0:detail_limit-3}...
  fi

  printf -v result_file '%s/result-%010d.tsv' "$temp_dir" "$address_value_to_scan"
  printf '%010d\t%s\t%s\t%s\t%s\t%s\n' "$address_value_to_scan" "$address" "$status" "$exit_code" "$duration" "$detail" >"$result_file"
}

printf '\nSSH Command Scanner\n'
printf 'Target: %s  Addresses: %s  User: %s  Port: %s  Parallel: %s  Timeout: %ss\n' "$canonical_target" "$target_count" "$username" "$port" "$concurrency" "$timeout_seconds"
printf 'Authentication: OpenSSH default keys, ssh-agent, or --identity.\n\n'

launched=0
for ((address_to_scan = first_value; address_to_scan <= last_value; address_to_scan++)); do
  while :; do
    running_jobs=$(jobs -pr | wc -l | tr -d '[:space:]')
    (( running_jobs < concurrency )) && break
    sleep 0.05
  done
  scan_one "$address_to_scan" &
  ((launched += 1))
  printf '\rScanning: %s / %s' "$launched" "$target_count"
done
wait
printf '\rScanning: %s / %s\n\n' "$target_count" "$target_count"

result_count=0
for result_file in "$temp_dir"/result-*.tsv; do
  [[ -f $result_file ]] && ((result_count += 1))
done
(( result_count == target_count )) || die "Expected ${target_count} results, received ${result_count}."
cat "$temp_dir"/result-*.tsv >"$temp_dir/results.tsv"

ip_width=2
status_width=6
exit_width=4
duration_width=8
detail_width=6

while IFS=$'\t' read -r _ ip status exit_code duration detail; do
  ((${#ip} > ip_width)) && ip_width=${#ip}
  ((${#status} > status_width)) && status_width=${#status}
  ((${#exit_code} > exit_width)) && exit_width=${#exit_code}
  ((${#duration} > duration_width)) && duration_width=${#duration}
  ((${#detail} > detail_width)) && detail_width=${#detail}
done <"$temp_dir/results.tsv"

make_border() {
  printf '+'
  printf '%*s' "$((ip_width + 2))" '' | tr ' ' '-'
  printf '+'
  printf '%*s' "$((status_width + 2))" '' | tr ' ' '-'
  printf '+'
  printf '%*s' "$((exit_width + 2))" '' | tr ' ' '-'
  printf '+'
  printf '%*s' "$((duration_width + 2))" '' | tr ' ' '-'
  printf '+'
  printf '%*s' "$((detail_width + 2))" '' | tr ' ' '-'
  printf '+\n'
}

render_table() {
  make_border
  printf '| %-*s | %-*s | %-*s | %-*s | %-*s |\n' \
    "$ip_width" 'IP' "$status_width" 'Status' "$exit_width" 'Exit' "$duration_width" 'Time(ms)' "$detail_width" 'Detail'
  make_border
  while IFS=$'\t' read -r _ ip status exit_code duration detail; do
    printf '| %-*s | %-*s | %-*s | %-*s | %-*s |\n' \
      "$ip_width" "$ip" "$status_width" "$status" "$exit_width" "$exit_code" "$duration_width" "$duration" "$detail_width" "$detail"
  done <"$temp_dir/results.tsv"
  make_border
}

render_table >"$temp_dir/table.txt"
summary_text=$(cut -f3 "$temp_dir/results.tsv" | sort | uniq -c | awk 'BEGIN {printf "Summary:"} {printf " %s=%s", $2, $1} END {print ""}')

cat "$temp_dir/table.txt"
printf '%s\n' "$summary_text"

if [[ -n $text_output_path ]]; then
  {
    printf 'SSH Command Scanner\n'
    printf 'Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Target: %s\n' "$canonical_target"
    printf 'Addresses: %s\n' "$target_count"
    printf 'User: %s\n' "$username"
    printf 'Port: %s\n\n' "$port"
    cat "$temp_dir/table.txt"
    printf '\n%s\n' "$summary_text"
  } >"$text_output_path"
  printf 'ASCII table: %s\n' "$text_output_path"
fi
