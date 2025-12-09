# SPDX-License-Identifier: MIT
ARG CUDA_VERSION
ARG UBUNTU_VERSION
ARG IMAGE_BASE=nvidia/cuda
ARG IMAGE_TAG=${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}

FROM nvidia/cuda:12.2.0-devel-ubuntu22.04

LABEL maintainer="UW Simulation Based Engineering Laboratory <negrut@wisc.edu>"

ARG DEBIAN_FRONTEND=noninteractive

# Check if the image is Ubuntu-based
RUN grep -qi "ubuntu" /etc/os-release || (echo "Error: Image is not Ubuntu-based" && exit 1)

# Various arguments and user settings
ARG USERNAME="chrono-user"
ARG USERHOME="/home/${USERNAME}"
ARG USERSHELL="bash"
ARG USERSHELLPATH="/bin/${USERSHELL}"
ARG USERSHELLPROFILE="${USERHOME}/.${USERSHELL}rc"

# Add ROS GPG key and to the sources list
RUN apt update && \
        apt install curl -y && \
        curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg && \
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null

# Install dependencies
ARG APT_DEPENDENCIES=""
RUN apt-get update && apt-get install --no-install-recommends -y python3-pip sudo ${APT_DEPENDENCIES}

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

ARG USER_GROUPS=""
RUN if [ -n "${USER_GROUPS}" ]; then \
			for g in ${USER_GROUPS}; do \
				getent group $g || groupadd $g; \
				usermod -aG $g ${USERNAME}; \
			done; \
    fi

# Move optix file into docker container
ARG OPTIX_SCRIPT
COPY ${OPTIX_SCRIPT} /tmp/optix.sh
RUN chmod +x /tmp/optix.sh && \
        mkdir /opt/optix && \
        /tmp/optix.sh --prefix=/opt/optix --skip-license && \
        rm /tmp/optix.sh


RUN apt-get update && apt-get install -y nano

WORKDIR ${USERHOME}
RUN apt update && \
    apt install wget -y && \
    wget https://bitbucket.org/blaze-lib/blaze/downloads/blaze-3.8.tar.gz && \
    tar -xvzf blaze-3.8.tar.gz && \
    mv blaze-3.8/blaze /usr/local/include/ && \
    rm -r blaze-3.8 blaze-3.8.tar.gz

# chrono_ros_interfaces
USER ${USERNAME}

ARG ROS_WORKSPACE_DIR="${USERHOME}/ros2_ws"
ARG CHRONO_ROS_INTERFACES_DIR="${ROS_WORKSPACE_DIR}/src/chrono_ros_interfaces"
RUN mkdir -p ${CHRONO_ROS_INTERFACES_DIR} && \
    git clone https://github.com/projectchrono/chrono_ros_interfaces.git ${CHRONO_ROS_INTERFACES_DIR} 
RUN /bin/bash -c "source /opt/ros/humble/setup.bash && cd ${ROS_WORKSPACE_DIR} && colcon build"

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
RUN echo "export PYTHONPATH=\"$USERHOME/mountdir/chrono/build/bin:\$PYTHONPATH\"" >> ${USERSHELLPROFILE}

CMD ${USERSHELLPATH}

# Source ROS setup.bash and build chrono_ros_interfaces during the container build process
RUN echo "source /opt/ros/humble/setup.sh" >> ${USERSHELLPROFILE}
RUN echo "source ${ROS_WORKSPACE_DIR}/install/setup.sh" >> ${USERSHELLPROFILE}


