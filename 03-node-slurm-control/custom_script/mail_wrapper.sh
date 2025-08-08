#!/bin/bash

JOB_ID=$SLURM_JOB_ID
JOB_NAME=$SLURM_JOB_NAME
JOB_USER=$SLURM_JOB_USER
JOB_STATE=$SLURM_JOB_STATE
MAIL_TYPE=$SLURM_JOB_MAIL_TYPE
MAIL_USER=$(scontrol show job $JOB_ID | grep -oP '(?<=MailUser=)[^ ]*')

exec >> /var/log/slurm/email.log 2>&1

if [ -z "$MAIL_USER" ]; then
    echo "No mail user specified for job $JOB_ID. Exiting..."
    exit 1
fi

SUBJECT="$JOB_ID - $JOB_NAME - $MAIL_TYPE"
BODY="用户名称: $JOB_USER</br>作业ID: $JOB_ID</br>作业名称: $JOB_NAME</br>作业状态: $JOB_STATE</br></br>"


json_payload=$(jq -n \
                  --arg name "$JOB_USER" \
                  --arg email "$MAIL_USER" \
                  --arg subject "$SUBJECT" \
                  --arg body "$BODY" \
                  '{
                    "toName": $name,
                    "toEmail": $email,
                    "fromName": "njust-slurm",
                    "fromEmail": "itgrape@outlook.com",
                    "secretKey": "pushihao",
                    "Subject": $subject,
                    "htmlContent": $body
                  }')

if [ -z "$json_payload" ]; then
    echo "Error: Failed to create JSON payload. Exiting..."
    exit 1
fi

max_retries=3
retry_delay=5
retry_count=0

while [ $retry_count -lt $max_retries ]; do
    http_code=$(curl -s -w "%{http_code}" -o /dev/null \
                     --location 'https://api.pushihao.com/v1/email' \
                     --header 'Content-Type: application/json' \
                     --data-raw "$json_payload")

    if [ $? -eq 0 ] && [ "$http_code" -eq 200 ]; then
        echo "Email sent successfully for job $JOB_ID to $MAIL_USER"
        break
    else
        retry_count=$((retry_count + 1))
        echo "Send failed (retry: $retry_count/$max_retries). exit code: $?, http code: $http_code"
        if [ $retry_count -lt $max_retries ]; then
            sleep $retry_delay
        else
            echo "Send failed after $max_retries retries. Exiting..."
            exit 1
        fi
    fi
done