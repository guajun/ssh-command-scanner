#!/usr/bin/env bash

set -uo pipefail

username=""
command_template=""
start_host=1
end_host=254
timeout_seconds=3
throttle_limit=32
text_output_path=""
detail_limit=54

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

show_help() {
  cat <<'EOF'
SSH Command Scanner

Options:
  --user USER
  --command-template TEMPLATE
  --start-host NUMBER
  --end-host NUMBER
  --timeout SECONDS
  --throttle-limit NUMBER
  --text-output-path PATH.txt
  -h, --help

The target may be IPv4.x, user@IPv4.x, or a full ssh command. Full commands
may use {user} as the username placeholder.
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
    --command-template)
      require_value "$@"
      command_template=$2
      shift 2
      ;;
    --start-host)
      require_value "$@"
      start_host=$2
      shift 2
      ;;
    --end-host)
      require_value "$@"
      end_host=$2
      shift 2
      ;;
    --timeout)
      require_value "$@"
      timeout_seconds=$2
      shift 2
      ;;
    --throttle-limit)
      require_value "$@"
      throttle_limit=$2
      shift 2
      ;;
    --text-output-path)
      require_value "$@"
      text_output_path=$2
      shift 2
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
  [[ -r /dev/tty ]] || die "Interactive input is unavailable; pass all required options."
  printf '%s' "$label" >/dev/tty
  IFS= read -r PROMPT_VALUE </dev/tty || die "Unable to read interactive input."
}

if [[ -z $username ]]; then
  prompt_value 'SSH username: '
  username=$PROMPT_VALUE
fi

[[ $username =~ ^[A-Za-z0-9._-]+$ ]] || die 'Username contains unsupported characters.'

if [[ -z $command_template ]]; then
  prompt_value 'SSH target or command (use x for the last IPv4 octet): '
  command_template=$PROMPT_VALUE
fi

[[ -n $command_template ]] || die 'SSH target or command cannot be empty.'
[[ $start_host =~ ^[0-9]+$ ]] || die 'start-host must be between 0 and 255.'
[[ $end_host =~ ^[0-9]+$ ]] || die 'end-host must be between 0 and 255.'
[[ $timeout_seconds =~ ^[0-9]+$ ]] || die 'timeout must be between 1 and 60.'
[[ $throttle_limit =~ ^[0-9]+$ ]] || die 'throttle-limit must be between 1 and 128.'
command -v ssh >/dev/null 2>&1 || die 'OpenSSH client was not found in PATH.'

start_host=$((10#$start_host))
end_host=$((10#$end_host))
timeout_seconds=$((10#$timeout_seconds))
throttle_limit=$((10#$throttle_limit))
(( start_host <= 255 )) || die 'start-host must be between 0 and 255.'
(( end_host <= 255 )) || die 'end-host must be between 0 and 255.'
(( start_host <= end_host )) || die 'start-host cannot be greater than end-host.'
(( timeout_seconds >= 1 && timeout_seconds <= 60 )) || die 'timeout must be between 1 and 60.'
(( throttle_limit >= 1 && throttle_limit <= 128 )) || die 'throttle-limit must be between 1 and 128.'

if [[ -n $text_output_path ]]; then
  output_name=${text_output_path##*/}
  if [[ $output_name != *.* ]]; then
    text_output_path=${text_output_path}.txt
  elif [[ $text_output_path != *.txt ]]; then
    die 'text-output-path must use the .txt extension.'
  fi

  output_directory=$(dirname "$text_output_path")
  [[ -d $output_directory ]] || die "Output directory does not exist: $output_directory"
fi

bare_target_regex='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[xX]$'
login_target_regex='^[A-Za-z0-9._-]+@[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[xX]$'
escaped_login_target_regex='^([A-Za-z0-9._-]+)\\@([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[xX])$'
if [[ $command_template =~ ^ssh(\.exe)?[[:space:]] ]]; then
  :
elif [[ $command_template =~ $bare_target_regex ]]; then
  command_template="ssh {user}@${command_template}"
elif [[ $command_template =~ $login_target_regex ]]; then
  command_template="ssh ${command_template}"
elif [[ $command_template =~ $escaped_login_target_regex ]]; then
  command_template="ssh ${BASH_REMATCH[1]}@${BASH_REMATCH[2]}"
else
  die 'Enter IPv4.x, user@IPv4.x, or a full command beginning with ssh.'
fi

template_with_user=${command_template//\{user\}/$username}
address_regex='(^|[^0-9])([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([xX])([^[:alnum:]]|$)'
[[ $template_with_user =~ $address_regex ]] || die 'Template must contain one IPv4 last-octet placeholder named x.'

first_octet=${BASH_REMATCH[2]}
second_octet=${BASH_REMATCH[3]}
third_octet=${BASH_REMATCH[4]}
placeholder_character=${BASH_REMATCH[5]}
first_octet=$((10#$first_octet))
second_octet=$((10#$second_octet))
third_octet=$((10#$third_octet))
(( first_octet <= 255 && second_octet <= 255 && third_octet <= 255 )) || die 'Template contains an invalid IPv4 network.'

prefix="${first_octet}.${second_octet}.${third_octet}"
target_placeholder="${prefix}.${placeholder_character}"
after_first=${template_with_user#*"$target_placeholder"}
[[ $after_first != *"$target_placeholder"* ]] || die 'Template must contain exactly one IPv4 placeholder.'

split_ssh_command() {
  local input=$1
  local token=""
  local quote=""
  local character=""
  local next_character=""
  local in_token=0
  local index
  SSH_TOKENS=()

  for ((index = 0; index < ${#input}; index++)); do
    character=${input:index:1}

    if [[ -n $quote ]]; then
      if [[ $character == "$quote" ]]; then
        quote=""
        in_token=1
      elif [[ $quote == '"' && $character == "\\" && $((index + 1)) -lt ${#input} ]]; then
        next_character=${input:index+1:1}
        if [[ $next_character == '"' ]]; then
          token+='"'
          ((index += 1))
        else
          token+=$character
        fi
      else
        token+=$character
      fi
      continue
    fi

    case "$character" in
      "'"|'"')
        quote=$character
        in_token=1
        ;;
      ' '|$'\t'|$'\r'|$'\n')
        if (( in_token )); then
          SSH_TOKENS+=("$token")
          token=""
          in_token=0
        fi
        ;;
      *)
        token+=$character
        in_token=1
        ;;
    esac
  done

  [[ -z $quote ]] || return 1
  if (( in_token )); then
    SSH_TOKENS+=("$token")
  fi
  ((${#SSH_TOKENS[@]} > 0)) || return 1

  local executable_name=${SSH_TOKENS[0]##*/}
  [[ $executable_name == ssh || $executable_name == ssh.exe ]]
}

sample_address="${prefix}.${start_host}"
sample_command=${template_with_user/"$target_placeholder"/"$sample_address"}
split_ssh_command "$sample_command" || die 'SSH command contains unbalanced quotes or an invalid executable.'

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

scan_one() {
  local host_number=$1
  local address="${prefix}.${host_number}"
  local rendered_command=${template_with_user/"$target_placeholder"/"$address"}
  local started finished duration output exit_code status detail full_detail result_file

  if ! split_ssh_command "$rendered_command"; then
    printf -v result_file '%s/result-%03d.tsv' "$temp_dir" "$host_number"
    printf '%03d\t%s\tother_error\t255\t0\tInvalid SSH command template\n' "$host_number" "$address" >"$result_file"
    return
  fi

  started=$(now_ms)
  output=$("${SSH_TOKENS[0]}" \
    -o BatchMode=yes \
    -o "ConnectTimeout=${timeout_seconds}" \
    -o ConnectionAttempts=1 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "${SSH_TOKENS[@]:1}" exit 2>&1)
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

  printf -v result_file '%s/result-%03d.tsv' "$temp_dir" "$host_number"
  printf '%03d\t%s\t%s\t%s\t%s\t%s\n' "$host_number" "$address" "$status" "$exit_code" "$duration" "$detail" >"$result_file"
}

total_hosts=$((end_host - start_host + 1))
printf '\nSSH Command Scanner\n'
printf 'Target: %s.%s-%s.%s  User: %s  Parallel: %s  Timeout: %ss\n' "$prefix" "$start_host" "$prefix" "$end_host" "$username" "$throttle_limit" "$timeout_seconds"
printf 'Authentication: OpenSSH default keys, ssh-agent, or an identity passed with -i.\n\n'

launched=0
for ((host_number = start_host; host_number <= end_host; host_number++)); do
  while :; do
    running_jobs=$(jobs -pr | wc -l | tr -d '[:space:]')
    (( running_jobs < throttle_limit )) && break
    sleep 0.05
  done
  scan_one "$host_number" &
  ((launched += 1))
  printf '\rScanning: %s / %s' "$launched" "$total_hosts"
done
wait
printf '\rScanning: %s / %s\n\n' "$total_hosts" "$total_hosts"

result_count=0
for result_file in "$temp_dir"/result-*.tsv; do
  [[ -f $result_file ]] && ((result_count += 1))
done
(( result_count == total_hosts )) || die "Expected ${total_hosts} results, received ${result_count}."
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
    printf 'Target: %s.%s-%s.%s\n' "$prefix" "$start_host" "$prefix" "$end_host"
    printf 'User: %s\n\n' "$username"
    cat "$temp_dir/table.txt"
    printf '\n%s\n' "$summary_text"
  } >"$text_output_path"
  printf 'ASCII table: %s\n' "$text_output_path"
fi
