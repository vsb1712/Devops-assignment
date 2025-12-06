#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
cd terraform

terraform init -upgrade
terraform apply -auto-approve

echo "Deployment complete."
echo "ALB DNS:"
terraform output -raw alb_dns_name
