log() {
     local timestamp
     timestamp=$(date +"%Y-%m-%d %T")
     local log_message="$timestamp [INFO] : $1"
     echo "$log_message"
}

fail() {
   set +x
   local -r all_args=("$@")
   local -r reason=$1
   local -r blob=("${all_args[@]:1}")


   if (( ${#blob[@]} )); then
     local line
     for line in "${blob[@]}"
     do
       >&2 echo "$line"
     done
   fi

   if [ -z "$reason" ]; then
     >&2 echo "FAILED"
   else
     >&2 echo "FAILED: $reason"
   fi

   exit 1
}

retry_with_backoff() {
  local retries=5
  local max_retries=5
  local delay=1

  local command_to_retry="$@"

  while (( retries > 0 )); do
    echo "Attempt: $((max_retries - retries + 1))"
    if eval "$command_to_retry"; then
      echo "Command executed successfully!"
      return 0
    else
      echo "Command failed. Retrying in $delay seconds..."
      sleep $delay
      (( delay *= 2 ))  # Exponential backoff, doubles the delay time
      (( retries-- ))
    fi
  done

  echo "Command failed after $max_retries attempts."
  return 1
}
