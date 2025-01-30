# Docker container with Chrono 9.0.1 with ROS2 Humble
### 1. Clone the repository
Run `git clone https://github.com/Auc7us/chrono-docker/`
##### Install [Git LFS](https://docs.github.com/en/repositories/working-with-files/managing-large-files/installing-git-large-file-storage) and
Run `git lfs pull`

### 2. Install [Docker Engine](https://docs.docker.com/engine/install/ubuntu/)
Run `sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`

### 3. Install [Autonomy-Toolkit (atk)](https://pypi.org/project/autonomy-toolkit/)
Run `pip install autonomy-toolkit`

#### (Sometimes you have to use sudo pip install followed by pip install to fix installation issues for atk)

### 5. Install [Nvidia Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

### 5. Make the script executable
Run `chmod +x setup_chrono_docker.sh`

### 6. Setup
Run `./setup_chrono_docker.sh`

### To spin up and attach to the container
Run `atk dev -ua -s chrono -o x11 gpus`

### To docker compose down, build, spin up and attach to the container
Run `atk dev -dbua -s chrono -o x11 gpus`