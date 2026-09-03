#!/usr/bin/env bash
set -euo pipefail

supabase test db

echo 'Database Core gate passed: complete pgTAP suite green with zero expected-failure quarantine.'
