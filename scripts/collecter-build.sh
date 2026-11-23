#!/usr/bin/env bash
# Run on YOUR machine: downloads and decrypts the logs of a "Build iOS" run.
# Usage: bash scripts/collecter-build.sh <run id> <output folder> [private_key.pem]
# Logs land in <output folder>/build-ios-<app>/results/build-ios-<app>/
exec bash "$(dirname "$0")/collecter-captures.sh" "$@"
