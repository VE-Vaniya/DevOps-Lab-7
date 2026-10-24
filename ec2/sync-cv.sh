#!/bin/bash
# Copies the site/ prefix of the CV bucket into the web root, stamps the
# footer with this instance's ID and logs one line per run.
# Credentials come from the instance role (cv-ec2-role-23l-3037), never from keys.

BUCKET="cv-23l-3037"
PREFIX="site/"
STAGING="/var/cv-staging"
WEBROOT="/var/www/html"
LOG="/var/log/cv-sync.log"

# IMDSv2: first get a session token with PUT, then send it with every metadata read.
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/region")

mkdir -p "$STAGING" "$WEBROOT"

# Sync into a staging folder first so the copy in S3 (with the placeholder)
# is never edited in place; then publish and replace the placeholder.
if aws s3 sync "s3://$BUCKET/$PREFIX" "$STAGING" --delete --region "$REGION" --only-show-errors \
   && cp -f "$STAGING"/* "$WEBROOT"/ \
   && sed -i "s/{{HOSTED_ON}}/EC2 $INSTANCE_ID/" "$WEBROOT/index.html"; then
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') sync OK instance=$INSTANCE_ID" >> "$LOG"
else
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') sync FAILED instance=$INSTANCE_ID" >> "$LOG"
  exit 1
fi
