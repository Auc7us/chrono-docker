#!/bin/bash

# SPDX-License-Identifier: MIT

# Exit immediately if a command exits with a non-zero status
set -e

echo "Extracting chrono-docker.zip..."
unzip chrono-docker.zip

echo "Changing directory to chrono-docker..."
cd chrono-docker

echo "Running atk development setup..."
atk dev -dbua -s chrono -o x11 gpus

echo "Setup complete."
