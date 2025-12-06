#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
cd terraform

ALB_DNS=$(terraform output -raw alb_dns_name)
echo "Testing ALB: http://${ALB_DNS}"

echo "GET /"
curl -sS "http://${ALB_DNS}/" || true

echo
echo "GET /health"
curl -sS "http://${ALB_DNS}/health" || true
echo
