#!/bin/bash
set -eo pipefail

FNAME=$(basename "$INPUT_FILE")
BASE="${FNAME%.xlsx}"
LOG_FILE="/app/logs/${BASE}.log"

mkdir -p "$OUTPUT_DIR" /app/logs

echo "======================================" | tee "$LOG_FILE"
echo "Container: $FNAME (Server $SERVER_ID)" | tee -a "$LOG_FILE"
echo "Framework-agnostic MULTI runner" | tee -a "$LOG_FILE"
echo "======================================" | tee -a "$LOG_FILE"

EXIT_CODE=0

# -------------------------------------------------
# MODE 1 → Scrapy project inside subfolder
# -------------------------------------------------


SCRAPY_PROJECT_DIR=$(find /app -maxdepth 2 -name "scrapy.cfg" -exec dirname {} \; | head -n 1)
if [ -n "$SCRAPY_PROJECT_DIR" ]; then

    echo "Scrapy project found in: $SCRAPY_PROJECT_DIR" | tee -a "$LOG_FILE"

    cd "$SCRAPY_PROJECT_DIR" || exit 1

    SPIDERS=$(scrapy list || true)

    if [ -z "$SPIDERS" ]; then
        echo "No spiders found!" | tee -a "$LOG_FILE"
        exit 1
    fi

    echo "Spiders found:" | tee -a "$LOG_FILE"
    echo "$SPIDERS" | tee -a "$LOG_FILE"

    for SPIDER in $SPIDERS; do

        OUTPUT_FILE="${OUTPUT_DIR}/${BASE}_$(date +%Y%m%d_%H%M%S)_output.xlsx"

        echo "--------------------------------------" | tee -a "$LOG_FILE"
        echo "Running spider: $SPIDER" | tee -a "$LOG_FILE"

        RUN_CMD="scrapy crawl $SPIDER -a input_file=\"$INPUT_FILE\" -a output_file=\"$OUTPUT_FILE\" "

        if command -v xvfb-run >/dev/null 2>&1; then
            RUN_CMD="xvfb-run -a $RUN_CMD"
        fi

        echo "Running: $RUN_CMD" | tee -a "$LOG_FILE"

        if eval $RUN_CMD 2>&1 | tee -a "$LOG_FILE"; then
            echo "Spider SUCCESS: $SPIDER" | tee -a "$LOG_FILE"
        else
            echo "Spider FAILED: $SPIDER" | tee -a "$LOG_FILE"
            EXIT_CODE=1
        fi

    done

    cd /app

else
    echo "No scrapy.cfg found → running scraper.py" | tee -a "$LOG_FILE"

    OUTPUT_FILE="${OUTPUT_DIR}/${BASE}_$(date +%Y%m%d_%H%M%S)_output.xlsx"
    RUN_CMD="python3 /app/scraper.py --input \"$INPUT_FILE\" --output \"$OUTPUT_FILE\""

    if command -v xvfb-run >/dev/null 2>&1; then
        RUN_CMD="xvfb-run -a $RUN_CMD"
    fi

    if eval $RUN_CMD 2>&1 | tee -a "$LOG_FILE"; then
        echo "SUCCESS: $FNAME" | tee -a "$LOG_FILE"
    else
        echo "FAILED: $FNAME" | tee -a "$LOG_FILE"
        EXIT_CODE=1
    fi
fi

# ---- Upload outputs ----
if [ -f "$OUTPUT_FILE" ]; then
    aws s3 cp "$OUTPUT_FILE" \
        "s3://${S3_BUCKET}/${S3_OUTPUT_PREFIX}${BASE}_$(date +%Y%m%d_%H%M%S)_output.xlsx" \
        --region "us-east-1" 2>&1 | tee -a "$LOG_FILE"
else
    echo "Output not found → skipping S3 upload" | tee -a "$LOG_FILE"
fi

aws s3 cp "$LOG_FILE" \
    "s3://${S3_BUCKET}/${S3_OUTPUT_PREFIX}logs/server-${SERVER_ID}/${BASE}.log" \
    --region "us-east-1" || true

exit $EXIT_CODE