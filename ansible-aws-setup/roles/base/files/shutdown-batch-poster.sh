#!/bin/bash

MESSAGE="TERMINATE"
PORT=8005

# Get the CID from active VSOCK connections on port 8004
CID=$(ss -A vsock | grep ESTAB | grep ':8004' | awk '{print $6}' | cut -d':' -f1 | head -n 1)

# Validate CID
if [[ ! "$CID" =~ ^[0-9]+$ ]]; then
    echo "Error: No valid CID found in active VSOCK connections"
    echo "Debug: Run 'ss -A vsock' to check connections"
    exit 1
fi

echo "Attempting VSOCK connection to CID $CID, port $PORT..."

# Run socat and capture output and exit status
OUTPUT=$(echo "$MESSAGE" | socat - VSOCK-CONNECT:$CID:$PORT 2>&1)
EXIT_STATUS=$?

echo "$OUTPUT"

# Handle connection results
if echo "$OUTPUT" | grep -q "Connection timed out"; then
    echo "Connection timed out for CID $CID: $OUTPUT"
    exit 1
elif [ $EXIT_STATUS -eq 0 ]; then
    echo "Success: Connected to CID $CID, port $PORT"
    exit 0
else
    echo "Error: Connection failed for CID $CID (Exit Status: $EXIT_STATUS)"
    echo "Output: $OUTPUT"
    exit 1
fi