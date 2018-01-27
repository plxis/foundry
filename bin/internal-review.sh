#!/bin/bash
if [[ $# -ne 1 ]]; then
  echo "Internal Account Review"
  echo "Usage: $0 <numberOfDaysToReview>"
  exit 1
fi
days=$1
bin=$(dirname $0)
$bin/monitor.sh --profile default --days $days --cloudTrailIncludeFilter IAM
$bin/monitor.sh --profile tmp --days $days --excludeCloudTrail
$bin/monitor.sh --profile eng --days $days