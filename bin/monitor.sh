#!/bin/bash
profile=default
region=us-east-1
days=1
includeCloudTrail=true
includeCloudWatch=true
cloudTrailIncludeFilter="-"
cloudTrailExcludeFilter="CreateLog\|CreateTags"
cloudWatchIncludeFilter="sshd opened"
cloudWatchExcludeFilter=unusedFilter

function usage() {
  script=$1
  echo "Run environment review for a specific AWS profile."
  echo "Usage: $script [options]"
  echo "  --help                     Output this usage information"
  echo "  --profile <awsProfile>     AWS profile to review [$profile]"
  echo "  --region <awsRegion>       AWS profile to review [$region]"
  echo "  --days <numDays>           Number of recent days to review [$days]"
  echo "  --excludeCloudTrail        If specified, CloudTrail will be skipped"
  echo "  --excludeCloudWatch        If specified, CloudWatch will be skipped"
  echo "  --cloudTrailIncludeFilter  Grep style inclusion filter for CloudTrail events [$cloudTrailIncludeFilter]"
  echo "  --cloudTrailExcludeFilter  Grep style exclusion filter for CloudTrail events [$cloudTrailExcludeFilter]"
  echo "  --cloudWatchIncludeFilter  AWS Pattern filter for locating matching log events [$cloudWatchIncludeFilter]"
  echo "  --cloudWatchExcludeFilter  Grep style exclusion filter for CloudTrail events [$cloudWatchExcludeFilter]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  if [[ $1 == "-h" || $1 == "--help" ]]; then
    usage $0
  elif [[ $1 == "--days" ]]; then
    shift
    days=$1
  elif [[ $1 == "--profile" ]]; then
    shift
    profile=$1
  elif [[ $1 == "--region" ]]; then
    shift
    region=$1
  elif [[ $1 == "--excludeCloudTrail" ]]; then
    includeCloudTrail=false
  elif [[ $1 == "--excludeCloudWatch" ]]; then
    includeCloudWatch=false
  elif [[ $1 == "--cloudTrailIncludeFilter" ]]; then
    shift
    cloudTrailIncludeFilter=$1
  elif [[ $1 == "--cloudTrailExcludeFilter" ]]; then
    shift
    cloudTrailExcludeFilter=$1
  elif [[ $1 == "--cloudWatchIncludeFilter" ]]; then
    shift
    cloudWatchIncludeFilter=$1
  elif [[ $1 == "--cloudWatchExcludeFilter" ]]; then
    shift
    cloudWatchExcludeFilter=$1
  else
    usage $0
  fi
  shift
done

if [[ -z $days || -z $profile ]]; then
  usage $0
fi

startDate=`date --date="$days days ago" +%FT%TZ`
startMillis=`date --date="$days days ago" +%s`000
aws="aws --profile $profile --region $region"

echo "Environment Review Report for $profile since $startDate"
echo "================================================================"
echo ""
echo "CloudTrail events (includeFilter=$cloudTrailIncludeFilter, excludeFilter=$cloudTrailExcludeFilter)" 
echo "-----------------"
if [ "$includeCloudTrail" != "true" ]; then
  echo "skipped"
else
  $aws cloudtrail lookup-events --start-time $startDate | \
    jq -r '.Events[] | "\(.EventTime) - User=\(.Username) --> \(.EventName) on \(.Resources[0].ResourceType)::\(.Resources[0].ResourceName)"' | \
    grep "$cloudTrailIncludeFilter" | \
    grep -v "$cloudTrailExcludeFilter" | \
    sort
fi
echo ""
echo "CloudWatch events (includeFilter=$cloudWatchIncludeFilter, excludeFilter=$cloudWatchExcludeFilter)" 
echo "-----------------"
if [ "$includeCloudWatch" != "true" ]; then
  echo "skipped"
else
  truncate --size 0 /tmp/monitor.tmp
  logGroups=`$aws logs describe-log-groups | jq -r '.logGroups[].logGroupName'`
  for group in $logGroups; do
    $aws logs filter-log-events --log-group-name $group --start-time $startMillis --filter-pattern "$cloudWatchIncludeFilter" | \
      jq -r ".events[] | \"\(.timestamp) - stream=$group::\(.logStreamName) --> \(.message)\"" | \
      grep -v "$cloudWatchExcludeFilter" >> /tmp/monitor.tmp
  done
  cat /tmp/monitor.tmp | sort
  rm -f /tmp/monitor.tmp
fi
echo ""
echo ""