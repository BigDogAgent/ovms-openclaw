#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Require explicit environment argument
if [ $# -ne 1 ] || { [ "$1" != "prod" ] && [ "$1" != "test" ]; }; then
  echo "Usage: $0 prod|test"
  exit 1
fi

ENV="$1"
ENV_FILE="$SCRIPT_DIR/.$ENV"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example to .$ENV and fill in credentials."
  exit 1
fi

source "$ENV_FILE"

# Registry login
echo "$REDHAT_PASSWORD" | podman login registry.connect.redhat.com \
  --username "$REDHAT_USERNAME" \
  --password-stdin

# Launch OVMS
podman run \
  --user $(id -u):$(id -g) \
  -d \
  --name ovms \
  -p 8000:8000 \
  --device /dev/dri \
  --device /dev/accel \
  --group-add keep-groups \
  --security-opt label=disable \
  -v ~/ovms/models:/models:rw \
  registry.connect.redhat.com/intel/openvino-model-server:2026.0-gpu \
  --config_path /models/config.json \
  --rest_port 8000 \
  --rest_bind_address 0.0.0.0
