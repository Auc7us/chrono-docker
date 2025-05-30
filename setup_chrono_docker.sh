#!/bin/bash

# SPDX-License-Identifier: MIT

# Exit immediately if a command exits with a non-zero status
set -e

echo "Setting up Python3 pip environment for installation"
python3 -m venv .chrono-env
source .chrono-env/bin/activate

echo "Installing autonomy-toolkit"
pip install autonomy-toolkit

echo "Installing additional python dependencies"
pip install numpy pandas

echo "Extracting chrono-orb.zip..."
unzip chrono-docker.zip

echo "Changing directory to chrono-docker..."
cd chrono-docker/mountdir
git clone -b 9.0.1 https://github.com/Auc7us/chrono.git

cd ..

echo "Running atk development setup..."
atk dev -dbua -s chrono -o x11 gpus

echo "Setup complete; Please run buildChronoInMount.sh located at /home/chrono-user/mountdir/ inside the container
 to build Chrono in a persistent mount directory on host"
