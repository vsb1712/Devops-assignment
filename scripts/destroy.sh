#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
cd terraform

terraform destroy -auto-approve
echo "Teardown complete."
