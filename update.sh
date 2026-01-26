#!/bin/bash
# update.sh
# Pull latest changes and restart all services

set -e

echo "--- Pulling latest changes from Git ---"
git pull

echo "--- Pulling latest Docker images ---"
docker compose pull

echo "--- Deploying stack ---"
docker compose up -d --remove-orphans

echo "--- Cleaning up old images ---"
docker image prune -f

echo "--- Done! ---"
echo ""
echo "Check status with: docker compose ps"
echo "View logs with:    docker compose logs -f"
