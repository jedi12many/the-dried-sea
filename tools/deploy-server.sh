#!/usr/bin/env bash
# Deploy The Dried Sea server to GCP and restart it. Run from repo root:
#   bash tools/deploy-server.sh
set -euo pipefail
VM="dried-sea-server"
ZONE="us-east1-b"
PROJECT="mycon-sandbox"

echo "== packing game + data =="
tar czf /tmp/dried-sea.tgz game data

echo "== uploading =="
gcloud compute scp /tmp/dried-sea.tgz "$VM":/tmp/ --zone="$ZONE" --project="$PROJECT" --quiet

echo "== installing + restarting =="
gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" --quiet --command='
  sudo mkdir -p /opt/dried-sea &&
  sudo tar xzf /tmp/dried-sea.tgz -C /opt/dried-sea &&
  sudo systemctl restart dried-sea &&
  sleep 3 && sudo journalctl -u dried-sea -n 3 --no-pager'
echo "== deployed =="
