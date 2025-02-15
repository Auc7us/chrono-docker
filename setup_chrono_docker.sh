#!/bin/bash

# SPDX-License-Identifier: MIT

# Exit immediately if a command exits with a non-zero status
set -e

echo "Extracting chrono-orb.zip..."
unzip chrono-docker.zip

echo "Changing directory to chrono-docker..."
cd chrono-docker/mountdir
git clone -b 9.0.1 https://github.com/Auc7us/chrono.git

cd ..

echo "Running atk development setup..."
sudo atk dev -dbua -s chrono -o x11 gpus

echo "Setup complete; Please run buildChronoInMount.sh located at ~/mountDrive inside the container
 to build Chrono in a persistent mount directory on host"
