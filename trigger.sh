#!/bin/bash
set -e
SCRAPER_DIR="/home/ubuntu/scraper"

sudo chown -R ubuntu:ubuntu "$SCRAPER_DIR"

LOG_FILE="$SCRAPER_DIR/logs/main.log"

mkdir -p "$SCRAPER_DIR/logs"

# ── Redirect to main.log + a timestamped run log ─────────────────────────────
# instance-agent pre-creates the run log and passes its path via $RUN_LOG env var
# so the Live Log WebSocket can start tailing it immediately with no race condition.
# If $RUN_LOG is not set (e.g. manual SSH run), create our own.
if [ -z "$RUN_LOG" ]; then
    RUN_LOG="$SCRAPER_DIR/logs/run_$(date +%Y%m%d_%H%M%S).log"
fi
exec > >(tee -a "$LOG_FILE" | tee -a "$RUN_LOG") 2>&1

echo "=========================================="
echo "TRIGGER.SH — $(date)"
echo "=========================================="

# ── Docker access ─────────────────────────────────────────────────────────────
# instance-agent runs as ubuntu. If ubuntu is in the docker group but the
# group membership wasn't active when the agent started (e.g. usermod ran after
# agent boot), docker commands will get "permission denied on docker.sock".
# Fix: use "sudo docker" so we never rely on group membership in this session.
DOCKER="sudo docker"

cd "$SCRAPER_DIR"

# ── Load config ───────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    echo "ERROR: .env not found"
    echo "STATUS=error" > "$SCRAPER_DIR/status.txt"
    exit 1
fi

source .env

echo "Server ID : $SERVER_ID"
echo "Region    : $AWS_REGION"

echo "STATUS=running" > "$SCRAPER_DIR/status.txt"

# ── Cleanup old containers ────────────────────────────────────────────────────
echo "[INFO] Cleaning old containers..."
$DOCKER ps -aq --filter "name=scraper_"  | xargs -r $DOCKER rm -f
$DOCKER ps -aq --filter "name=selenium_" | xargs -r $DOCKER rm -f
$DOCKER network rm scraper-net 2>/dev/null || true
rm -f "$SCRAPER_DIR/output/"*.xlsx 2>/dev/null || true



# ── IAM credential refresh function ──────────────────────────────────────────
# Called once at startup AND before each file, so tokens never expire mid-run.
# EC2 instance profile tokens can expire after 1-6 hours; long Selenium runs
# will hit this if credentials are only fetched once.
refresh_iam_credentials() {
    echo "[INFO] Refreshing IAM credentials..."
    ROLE_NAME=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/)
    CREDS=$(curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME")
    export AWS_ACCESS_KEY_ID=$(echo "$CREDS"     | python3 -c "import sys,json;print(json.load(sys.stdin)['AccessKeyId'])")
    export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['SecretAccessKey'])")
    export AWS_SESSION_TOKEN=$(echo "$CREDS"     | python3 -c "import sys,json;print(json.load(sys.stdin)['Token'])")
    echo "[INFO] IAM credentials refreshed"
}

# Initial refresh at startup
refresh_iam_credentials



# ── Detect GitLab by URL OR token prefix (glpat- = GitLab PAT) ───────────────
is_gitlab() {
    echo "$GITHUB_REPO" | grep -qi "gitlab" || echo "$GITHUB_TOKEN" | grep -q "^glpat-"
}

# ── Build authenticated URL ───────────────────────────────────────────────────
build_auth_url() {
    local url="$1"
    # Convert SSH to HTTPS first
    if echo "$url" | grep -q "^git@"; then
        if is_gitlab; then
            url=$(echo "$url" | sed "s|git@gitlab.com:|https://gitlab.com/|")
        else
            url=$(echo "$url" | sed "s|git@github.com:|https://github.com/|")
        fi
    fi
    if [ -n "$GITHUB_TOKEN" ]; then
        if is_gitlab; then
            url=$(echo "$url" | sed "s|https://|https://oauth2:$GITHUB_TOKEN@|")
        else
            url=$(echo "$url" | sed "s|https://|https://$GITHUB_TOKEN@|")
        fi
    fi
    echo "$url"
}

# ── Pull latest repo ──────────────────────────────────────────────────────────
echo "[INFO] Pulling latest code..."

if [ -d "$SCRAPER_DIR/repo/.git" ]; then
    cd "$SCRAPER_DIR/repo"
    # Update remote URL with fresh token auth
    AUTHED_URL=$(build_auth_url "$GITHUB_REPO")
    git remote set-url origin "$AUTHED_URL"
    git pull origin "$GITHUB_BRANCH" || echo "[WARN] git pull failed — using existing code"
    cd "$SCRAPER_DIR"
else
    echo "[INFO] repo not found — cloning fresh..."
    AUTHED_URL=$(build_auth_url "$GITHUB_REPO")
    git clone -b "$GITHUB_BRANCH" "$AUTHED_URL" "$SCRAPER_DIR/repo"
fi

# ── Build scraper image ───────────────────────────────────────────────────────
echo "[INFO] Building Docker image..."
$DOCKER build -t scraper-image "$SCRAPER_DIR/repo"
echo "[INFO] Docker image ready"

# ── Create docker network ─────────────────────────────────────────────────────
$DOCKER network create scraper-net 2>/dev/null || true

# ── List input files ──────────────────────────────────────────────────────────
LOCAL_INPUT_DIR="$SCRAPER_DIR/input"
ls "$LOCAL_INPUT_DIR"/*.xlsx 2>/dev/null | xargs -n1 basename | sort > /tmp/my_files.txt || true
FILE_COUNT=$(grep -c . /tmp/my_files.txt 2>/dev/null || echo 0)
echo "[INFO] Input files: $FILE_COUNT"

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "[WARN] No input files found in $LOCAL_INPUT_DIR"
    echo "STATUS=idle" > "$SCRAPER_DIR/status.txt"
    exit 0
fi

SUCCESS_COUNT=0
FAIL_COUNT=0
FILE_NUM=0

# ── Process files ─────────────────────────────────────────────────────────────
while IFS= read -r fname; do
    [ -z "$fname" ] && continue

    FILE_NUM=$((FILE_NUM + 1))
    echo ""
    echo "--- File $FILE_NUM / $FILE_COUNT : $fname ---"

    refresh_iam_credentials
    SAFE=$(echo "$fname" | tr '. -' '_' | tr '[:upper:]' '[:lower:]')
    echo "[INFO] Starting Selenium"
    # Force-remove any leftover containers with this name before starting fresh
    # (handles the case where a previous run crashed and set -e prevented cleanup)
    $DOCKER rm -f "selenium_${SAFE}" "scraper_${SAFE}" >/dev/null 2>&1 || true

    $DOCKER run -d \
        --name "selenium_${SAFE}" \
        --network scraper-net \
        --shm-size="2g" \
        selenium/standalone-chrome:latest

    echo "[INFO] Waiting for Selenium..."
    SELENIUM_READY=0
    for i in $(seq 1 30); do
        if $DOCKER exec "selenium_${SAFE}" curl -sf http://localhost:4444/wd/hub/status >/dev/null 2>&1; then
            echo "[INFO] Selenium ready (attempt $i)"
            SELENIUM_READY=1
            break
        fi
        sleep 2
    done
    if [ "$SELENIUM_READY" -eq 0 ]; then
        echo "[WARN] Selenium did not become ready after 60s — proceeding anyway"
    fi

    echo "[INFO] Starting scraper container"
    $DOCKER run \
        --name "scraper_${SAFE}" \
        --network scraper-net \
        -v "$SCRAPER_DIR/input/$fname:/app/input/$fname" \
        -v "$SCRAPER_DIR/output:/app/output" \
        -v "$SCRAPER_DIR/logs:/app/logs" \
        -e INPUT_FILE="/app/input/$fname" \
        -e OUTPUT_DIR="/app/output" \
        -e S3_BUCKET="$S3_BUCKET" \
        -e S3_OUTPUT_PREFIX="$S3_OUTPUT_PREFIX" \
        -e AWS_REGION="$AWS_REGION" \
        -e AWS_DEFAULT_REGION="$AWS_REGION" \
        -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
        -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
        -e AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
        -e SERVER_ID="$SERVER_ID" \
        -e SELENIUM_HUB_URL="http://selenium_${SAFE}:4444/wd/hub" \
        scraper-image

    EXIT_CODE=$($DOCKER inspect "scraper_${SAFE}" --format='{{.State.ExitCode}}')

    if [ "$EXIT_CODE" = "0" ]; then
        echo "[OK] SUCCESS: $fname"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "[ERROR] FAILED: $fname (exit $EXIT_CODE)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        {
            echo "=== $(date) FAILED: $fname ==="
            $DOCKER logs "scraper_${SAFE}" | tail -50
            echo ""
        } >> "$SCRAPER_DIR/error.log"
    fi

    $DOCKER rm -f "scraper_${SAFE}" "selenium_${SAFE}" >/dev/null 2>&1 || true

done < /tmp/my_files.txt

echo ""
echo "=========================================="
echo "DONE — Success=$SUCCESS_COUNT Failed=$FAIL_COUNT"
echo "=========================================="

# ── Final status ──────────────────────────────────────────────────────────────
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "STATUS=success" > "$SCRAPER_DIR/status.txt"
else
    echo "STATUS=error" > "$SCRAPER_DIR/status.txt"
fi

refresh_iam_credentials

# ── Upload log to S3 ──────────────────────────────────────────────────────────
aws s3 cp "$SCRAPER_DIR/logs/main.log" \
    "s3://$S3_BUCKET/${S3_OUTPUT_PREFIX}logs/server-${SERVER_ID}/trigger.log" \
    --region "us-east-1" || true

# ── SNS notification ──────────────────────────────────────────────────────────
MY_FILES_LIST=$(tr '\n' ' ' < /tmp/my_files.txt)
if [ "$FAIL_COUNT" -eq 0 ]; then
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID SUCCESS"
    MESSAGE="All files processed successfully: $MY_FILES_LIST"
else
    SUBJECT="[$PROJECT_NAME] Server $SERVER_ID PARTIAL FAILURE"
    MESSAGE="Success=$SUCCESS_COUNT Failed=$FAIL_COUNT | Files: $MY_FILES_LIST"
fi

aws sns publish \
    --topic-arn "$SNS_TOPIC_ARN" \
    --subject "$SUBJECT" \
    --message "$MESSAGE" \
    --region "$AWS_REGION" || true

if [ "$FAIL_COUNT" -eq 0 ]; then
    if [ "$AUTO_TERMINATE" = "true" ]; then
        echo "Terminating instance..."
        echo "Auto-terminating in 60 seconds..."
        echo "STATUS=idle" > "$SCRAPER_DIR"/status.txt
        sleep 60
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    else
        echo "STATUS=idle" > "$SCRAPER_DIR"/status.txt
        echo "Stopping instance..."
        sleep 60
        aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
    fi
else
    echo "STATUS=error" > "$SCRAPER_DIR"/status.txt
    echo "Failures occurred — instance will NOT stop"
fi