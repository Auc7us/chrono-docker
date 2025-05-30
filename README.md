# Docker container with Chrono 9.0.1 with ROS2 Humble
### 1. Clone the repository
 
```
git clone https://github.com/Auc7us/chrono-docker/
```
##### Install [Git LFS](https://docs.github.com/en/repositories/working-with-files/managing-large-files/installing-git-large-file-storage) and
 
```
git lfs pull
```

### 2. Install [Docker Engine](https://docs.docker.com/engine/install/ubuntu/)
 
```
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 3. Install Python Venv
```
sudo apt update
sudo apt install python3-venv -y
```

##### Note: You might have to use sudo pip install autonomy-toolkit followed by pip install autonomy-toolkit to fix installation issues for atk.

### 4. Install [Nvidia Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) 

### 5. Setup
- __Build the docker image__
 
    ```
    chmod +x setup_chrono_docker.sh
    ./setup_chrono_docker.sh
    ```

-  __Inside the container, build Chrono in the persistent mount directory on host using :__
    ```
    cd ..
    chmod +x buildChronoInMount.sh
    ./buildChronoInMount.sh
    ```


### 6. Run Container

- __To spin up and attach to the container__
 
    ```
    atk dev -ua -s chrono -o x11 gpus
    ```

- __To docker compose down, build, spin up and attach to the container__
 
    ```
    atk dev -dbua -s chrono -o x11 gpus
    ```

- Understanding -dbua flags:
    - d :  Stop and remove containers (docker compose down)
    - b : build docker image (docker build)
    - u : spin up a new docker container (docker compose up)
    - a : attach to a running docker container (docker exec or docker attach)
