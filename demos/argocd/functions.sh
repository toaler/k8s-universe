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
