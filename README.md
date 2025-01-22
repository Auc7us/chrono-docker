# Docker container with Chrono 9.0.1 with ROS2 Humble
### 1. Clone the repository
Run `git clone https://github.com/Auc7us/chrono-docker/`
##### Install Git LFS
Run `git lfs pull`

### 2. Install docker engine
Run `sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`
### 3. Install atk
Run `pip install autonomy-toolkit`
### 4. Add atk install dir to $PATH

### 5. Install [Nvidia Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
### 5. Make the script executable
Run `chmod +x setup_chrono_docker.sh`
### 6. Setup
Run `./setup_chrono_docker.sh`

### To spin up and attach to the container
Run `atk dev -ua -s chrono -o x11 gpus`

### To docker compose down, build, spin up and attach to the container
Run `atk dev -dbua -s chrono -o x11 gpus`
