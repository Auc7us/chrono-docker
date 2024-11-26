# Docker container with Chrono 9.0.1 with ROS2 Humble
### 1. Clone the repository
### 2. Make the script executable
 Run `chmod +x setup_chrono_docker.sh`
### 3. Setup
Run `./ setup_chrono_docker.sh`

### To spin up and attach to the container
Run `atk dev -ua -s chrono -o x11 gpus`

### To docker compose down, build, spin up and attach to the container
Run `atk dev -dbua -s chrono -o x11 gpus`
