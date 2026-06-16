# SPDX-License-Identifier: MIT
ARG CUDA_VERSION=13.2.1
ARG UBUNTU_VERSION=22.04
ARG IMAGE_BASE=nvidia/cuda
ARG IMAGE_TAG=${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}

FROM ${IMAGE_BASE}:${IMAGE_TAG}

LABEL maintainer="UW Simulation Based Engineering Laboratory <pachipala@wisc.edu>"

ARG DEBIAN_FRONTEND=noninteractive

# Check if the image is Ubuntu-based
RUN grep -qi "ubuntu" /etc/os-release || (echo "Error: Image is not Ubuntu-based" && exit 1)

# Various arguments and user settings
ARG USERNAME="chrono-user"
ARG USERHOME="/home/${USERNAME}"
ARG USERSHELL="bash"
ARG USERSHELLPATH="/bin/${USERSHELL}"
ARG USERSHELLPROFILE="${USERHOME}/.${USERSHELL}rc"
ARG ROS_DISTRO="humble"

# Add ROS GPG key and to the sources list
RUN apt update && \
        apt install --no-install-recommends -y curl gnupg lsb-release software-properties-common ca-certificates && \
        add-apt-repository universe && \
        curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg && \
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null

# Install dependencies (Chrono common + build + ROS base)
ARG APT_DEPENDENCIES=""
RUN apt-get update && apt-get install --no-install-recommends -y \
    python3-pip \
    python-is-python3 \
    sudo \
    git \
    cmake \
    build-essential \
    ninja-build \
    swig \
    libirrlicht-dev \
    libeigen3-dev \
    libxxf86vm-dev \
    freeglut3-dev \
    python3-numpy \
    libglu1-mesa-dev \
    libglew-dev \
    libglfw3-dev \
    libblas-dev \
    liblapack-dev \
    wget \
    unzip \
    xorg-dev \
    xauth \
    python3-colcon-common-extensions \
    ros-${ROS_DISTRO}-ros-base \
    ${APT_DEPENDENCIES}

# Vulkan SDK for Chrono::VSG
RUN wget -qO- https://packages.lunarg.com/lunarg-signing-key-pub.asc | tee /etc/apt/trusted.gpg.d/lunarg.asc && \
    UBUNTU_CODENAME=$(lsb_release -cs) && \
    wget -qO /etc/apt/sources.list.d/lunarg-vulkan.list "http://packages.lunarg.com/vulkan/lunarg-vulkan-${UBUNTU_CODENAME}.list" && \
    apt update && \
    apt install --no-install-recommends -y vulkan-sdk

# Clean up to reduce image size
RUN apt-get clean && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# Install some python packages
ARG PIP_REQUIREMENTS=""
RUN if [ -n "${PIP_REQUIREMENTS}" ]; then \
        pip install "${PIP_REQUIREMENTS}"; \
    fi

# Add user and grant sudo permission.
ARG USER_UID=1000
ARG USER_GID=1000
RUN adduser --shell ${USERSHELLPATH} --disabled-password --gecos "" ${USERNAME} && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}
RUN groupmod -o -g ${USER_GID} ${USERNAME}
RUN usermod -u ${USER_UID} -g ${USER_GID} ${USERNAME}
RUN mkdir -p /tmp/runtime-${USERNAME} && \
    chown ${USER_UID}:${USER_GID} /tmp/runtime-${USERNAME} && \
    chmod 700 /tmp/runtime-${USERNAME}

ARG USER_GROUPS=""
RUN if [ -n "${USER_GROUPS}" ]; then \
			for g in ${USER_GROUPS}; do \
				getent group $g || groupadd $g; \
				usermod -aG $g ${USERNAME}; \
			done; \
    fi

# Copy the packaged OptiX installer into the image; buildChronoInMount.sh extracts it on demand.
ARG OPTIX_ARCHIVE
COPY ${OPTIX_ARCHIVE} /opt/optix-installer/sensor-dep.zip
COPY ros_entrypoint.sh /opt/ros_entrypoint.sh
RUN chmod +x /opt/ros_entrypoint.sh && \
        mkdir -p /opt/optix-installer

RUN apt-get update && apt-get install -y nano

# chrono_ros_interfaces
USER ${USERNAME}

ARG ROS_WORKSPACE_DIR="${USERHOME}/ros2_ws"
ARG CHRONO_ROS_INTERFACES_DIR="${ROS_WORKSPACE_DIR}/src/chrono_ros_interfaces"
RUN mkdir -p ${CHRONO_ROS_INTERFACES_DIR} && \
    git clone https://github.com/projectchrono/chrono_ros_interfaces.git ${CHRONO_ROS_INTERFACES_DIR} 
RUN /bin/bash -c "source /opt/ros/${ROS_DISTRO}/setup.bash && cd ${ROS_WORKSPACE_DIR} && colcon build"

# User config
USER ${USERNAME}

# Default bash config
RUN mkdir -p ${USERHOME} && touch ${USERSHELLPROFILE}
RUN if [ "${USERSHELL}" = "bash" ]; then \
        echo 'export TERM=xterm-256color' >> ${USERSHELLPROFILE}; \
        echo 'export PS1="\[\033[38;5;40m\]\h\[$(tput sgr0)\]:\[$(tput sgr0)\]\[\033[38;5;39m\]\w\[$(tput sgr0)\]\\$ \[$(tput sgr0)\]"' >> ${USERSHELLPROFILE}; \
    fi

WORKDIR ${USERHOME}
ENV HOME=${USERHOME}
ENV USERSHELLPATH=${USERSHELLPATH}
ENV USERSHELLPROFILE=${USERSHELLPROFILE}
ENV ROS_DISTRO=${ROS_DISTRO}
ENV VSG_FILE_PATH=${USERHOME}/mountdir/packages/vsg/share/vsgExamples
ENV XDG_RUNTIME_DIR=/tmp/runtime-${USERNAME}
RUN echo "export PYTHONPATH=\"${USERHOME}/mountdir/lib/chrono-build/share/chrono/python:${USERHOME}/mountdir/chrono/build/bin:\$PYTHONPATH\"" >> ${USERSHELLPROFILE}
RUN echo "export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:${USERHOME}/mountdir/lib/chrono-build/lib:${USERHOME}/mountdir/packages/vsg/lib:${USERHOME}/mountdir/packages/urdf/lib" >> ${USERSHELLPROFILE}
RUN echo "export VSG_FILE_PATH=\"${VSG_FILE_PATH}\"" >> ${USERSHELLPROFILE}
RUN echo "export XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR}\"" >> ${USERSHELLPROFILE}

CMD ${USERSHELLPATH}

# Source ROS setup.bash and build chrono_ros_interfaces during the container build process
RUN echo "source /opt/ros/${ROS_DISTRO}/setup.sh" >> ${USERSHELLPROFILE}
RUN echo "source ${ROS_WORKSPACE_DIR}/install/setup.sh" >> ${USERSHELLPROFILE}
ENTRYPOINT ["/opt/ros_entrypoint.sh"]
