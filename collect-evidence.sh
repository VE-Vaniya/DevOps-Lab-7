#!/bin/bash
# Collects evidence for the CV-on-AWS lab into evidence.txt.
# Usage: ./collect-evidence.sh <bucket-name> <ec2-address> <lambda-address>
# Run it in AWS CloudShell (already signed in, no access keys needed).

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <bucket-name> <ec2-address> <lambda-address>"
  exit 1
fi

ROLL="23l-3037"
BUCKET="$1"
EC2_URL="$2"
LAMBDA_URL="$3"

EC2_ROLE="cv-ec2-role-$ROLL"
LAMBDA_ROLE="cv-lambda-role-$ROLL"
INSTANCE_NAME="cv-ec2-$ROLL"
FUNCTION="cv-func-$ROLL"
LOG_GROUP="/aws/lambda/$FUNCTION"
OUT="evidence.txt"

# Accept addresses with or without http(s):// and a trailing slash.
case "$EC2_URL" in http://*|https://*) ;; *) EC2_URL="http://$EC2_URL" ;; esac
case "$LAMBDA_URL" in http://*|https://*) ;; *) LAMBDA_URL="https://$LAMBDA_URL" ;; esac
EC2_URL="${EC2_URL%/}"
LAMBDA_URL="${LAMBDA_URL%/}"

: > "$OUT"

section() {
  echo "" >> "$OUT"
  echo "== $1 ==" >> "$OUT"
}

# Runs a command, appends its output, and notes a failure without stopping.
run() {
  echo "\$ $*" >> "$OUT"
  if ! "$@" >> "$OUT" 2>&1; then
    echo "!! command failed: $*" >> "$OUT"
  fi
}

# Prints "status content-type" for one URL.
probe() {
  local code
  code=$(curl -s -o /dev/null --max-time 15 -w "%{http_code} %{content_type}" "$1")
  echo "$1 -> $code" >> "$OUT"
}

echo "Evidence collected $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$OUT"

section "caller"
run aws sts get-caller-identity

section "public-access"
run aws s3api get-public-access-block --bucket "$BUCKET"

section "versioning"
run aws s3api get-bucket-versioning --bucket "$BUCKET"

section "objects"
run aws s3 ls "s3://$BUCKET/site/" --recursive --human-readable

section "ec2-policy"
for p in $(aws iam list-role-policies --role-name "$EC2_ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
  run aws iam get-role-policy --role-name "$EC2_ROLE" --policy-name "$p"
done
run aws iam list-attached-role-policies --role-name "$EC2_ROLE"

section "lambda-policy"
run aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE"
for p in $(aws iam list-role-policies --role-name "$LAMBDA_ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
  run aws iam get-role-policy --role-name "$LAMBDA_ROLE" --policy-name "$p"
done

section "security-group"
SG_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text 2>/dev/null)
if [ -n "$SG_IDS" ]; then
  run aws ec2 describe-security-groups --group-ids $SG_IDS \
    --query 'SecurityGroups[].{Group:GroupId,Name:GroupName,Inbound:IpPermissions}'
else
  echo "!! no running instance named $INSTANCE_NAME found" >> "$OUT"
fi

section "instance"
run aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,PublicIp:PublicIpAddress,HttpTokens:MetadataOptions.HttpTokens,InstanceProfile:IamInstanceProfile.Arn,Tags:Tags}'

section "endpoints"
probe "$EC2_URL/"
probe "$EC2_URL/style.css"
probe "$EC2_URL/cv.pdf"
probe "$LAMBDA_URL/"
probe "$LAMBDA_URL/style.css"
probe "$LAMBDA_URL/cv.pdf"
probe "$LAMBDA_URL/anything"
probe "https://$BUCKET.s3.amazonaws.com/site/index.html"

section "lambda-logs"
LOG_LINES=$(aws logs tail "$LOG_GROUP" --since 1d --format short 2>&1)
if [ $? -eq 0 ]; then
  echo "$LOG_LINES" | grep '"fn"' | tail -n 10 >> "$OUT"
else
  echo "$LOG_LINES" >> "$OUT"
  echo "!! command failed: aws logs tail $LOG_GROUP" >> "$OUT"
fi

section "log-retention"
run aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query 'logGroups[].{Name:logGroupName,RetentionDays:retentionInDays}'

echo "DONE"
