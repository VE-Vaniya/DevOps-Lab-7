#!/bin/bash
# EC2 user data: runs once, as root, on the first boot of the instance.
# 1. install and start Apache (httpd)
# 2. install the sync script and a systemd timer that runs it every 2 minutes
# 3. run the sync once now
set -euxo pipefail

dnf install -y httpd
systemctl enable --now httpd

# --- same content as ec2/sync-cv.sh in the repository ---
cat > /usr/local/bin/sync-cv.sh <<'SCRIPT'
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
SCRIPT
chmod 755 /usr/local/bin/sync-cv.sh

# Amazon Linux 2023 has no cron, so schedule the script with a systemd timer.
cat > /etc/systemd/system/cv-sync.service <<'UNIT'
[Unit]
Description=Sync the CV site from S3 into the web root
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
UNIT

cat > /etc/systemd/system/cv-sync.timer <<'UNIT'
[Unit]
Description=Run cv-sync every 2 minutes

[Timer]
OnBootSec=1min
OnCalendar=*:0/2
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now cv-sync.timer

# First sync right away. Do not let a failure here abort user data:
# the timer retries every 2 minutes.
/usr/local/bin/sync-cv.sh || true
