#!/bin/bash

# test-plus.sh - Test script for imsg-plus features
# This demonstrates the new commands with graceful degradation

IMSG="./.build/release/imsg"

echo "==================================="
echo "imsg-plus Feature Test"
echo "==================================="
echo

echo "1. Checking status..."
$IMSG status
echo

echo "2. Testing typing indicator (will show error if unavailable)..."
echo "   Command: $IMSG typing --handle test@example.com --state on"
$IMSG typing --handle test@example.com --state on 2>&1 | head -5
echo

echo "3. Testing read receipts (will show error if unavailable)..."
echo "   Command: $IMSG read --handle test@example.com"
$IMSG read --handle test@example.com 2>&1 | head -5
echo

echo "4. Testing reactions (will show error if unavailable)..."
echo "   Command: $IMSG react --handle test@example.com --guid TEST-123 --type love"
$IMSG react --handle test@example.com --guid TEST-123 --type love 2>&1 | head -5
echo

echo "5. Testing JSON output..."
echo "   Command: $IMSG status --json"
$IMSG status --json | python3 -m json.tool
echo

echo "==================================="
echo "Test complete!"
echo "==================================="
echo
echo "Note: Advanced features show helpful error messages when unavailable."
echo "This demonstrates graceful degradation - basic messaging still works!"