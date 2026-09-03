#!/usr/bin/env bash
set -euo pipefail

supabase test db

echo 'Item 2A database gate passed: complete pgTAP suite green with zero Item 2C exceptions.'
