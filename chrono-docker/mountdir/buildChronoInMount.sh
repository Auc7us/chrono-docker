#!/usr/bin/env bash
set -euo pipefail

ROS_DISTRO=${ROS_DISTRO:-humble}
PACKAGE_DIR=${PACKAGE_DIR:-"$HOME/packages"}
INSTALL_PREFIX=${INSTALL_PREFIX:-"$HOME/mountdir/lib/chrono-build"}
VSG_FILE_PATH="${PACKAGE_DIR}/vsg/share/vsgExamples"
CHRONO_CUDA_ARCHITECTURES=${CHRONO_CUDA_ARCHITECTURES:-89}
BLAZE_INCLUDE_DIR=${BLAZE_INCLUDE_DIR:-/usr/local/include}
URDF_PREFIX="${PACKAGE_DIR}/urdf"

cd "$(dirname "$0")"
cd chrono

mkdir -p "${PACKAGE_DIR}"

echo "Ensuring Blaze 3.8 headers are present..."
if [ ! -f "/usr/local/include/blaze/system/Version.h" ]; then
    TMP_BLAZE="$(mktemp -d)"
    pushd "${TMP_BLAZE}" >/dev/null
    wget -q https://bitbucket.org/blaze-lib/blaze/downloads/blaze-3.8.tar.gz
    tar -xzf blaze-3.8.tar.gz
    sudo rm -rf /usr/local/include/blaze
    sudo mv blaze-3.8/blaze /usr/local/include/
    popd >/dev/null
    rm -rf "${TMP_BLAZE}"
fi

echo "Ensuring URDF dependencies are built..."
if [ ! -d "${PACKAGE_DIR}/urdf" ]; then
    bash contrib/build-scripts/linux/buildURDF.sh "${PACKAGE_DIR}/urdf"
fi

echo "Ensuring VSG dependencies are built..."
if [ ! -d "${PACKAGE_DIR}/vsg" ]; then
    bash contrib/build-scripts/linux/buildVSG.sh "${PACKAGE_DIR}/vsg"
fi

ROS_SETUP="/opt/ros/${ROS_DISTRO}/setup.sh"
if [ -f "${ROS_SETUP}" ]; then
    # shellcheck source=/dev/null
    set +u
    source "${ROS_SETUP}"
    set -u
fi

CUDA_STUBS=$(find /usr/local/cuda/ -type d -name stubs | head -n 1)
CUDA_STUBS=${CUDA_STUBS:-/usr/local/cuda/lib64/stubs}
NUMPY_INC=$(python3 - <<'PY'
import numpy
print(numpy.get_include())
PY
)

mkdir -p build && cd build
echo "Running cmake..."
cmake ../ -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_DEMOS=ON \
        -DBUILD_BENCHMARKING=OFF \
        -DBUILD_TESTING=OFF \
        -DCH_ENABLE_MODULE_VEHICLE=ON \
        -DCH_ENABLE_MODULE_IRRLICHT=ON \
        -DCH_ENABLE_MODULE_PYTHON=ON \
        -DCH_ENABLE_MODULE_SENSOR=ON \
        -DCH_ENABLE_MODULE_ROS=ON \
        -DCH_ENABLE_MODULE_MULTICORE=ON \
        -DCH_ENABLE_MODULE_VSG=ON \
        -DCH_ENABLE_MODULE_PARSERS=ON \
        -DCHRONO_CUDA_ARCHITECTURES=${CHRONO_CUDA_ARCHITECTURES} \
        -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda \
        -Dblaze_INCLUDE_DIR=${BLAZE_INCLUDE_DIR} \
        -DEigen3_DIR=/usr/lib/cmake/eigen3 \
        -DOptiX_INCLUDE_DIR=/opt/optix/include \
        -DOptiX_INSTALL_DIR=/opt/optix \
        -Dvsg_DIR=${PACKAGE_DIR}/vsg/lib/cmake/vsg \
        -DvsgImGui_DIR=${PACKAGE_DIR}/vsg/lib/cmake/vsgImGui \
        -DvsgXchange_DIR=${PACKAGE_DIR}/vsg/lib/cmake/vsgXchange \
        -Durdfdom_DIR=${URDF_PREFIX}/lib/urdfdom/cmake \
        -Durdfdom_headers_DIR=${URDF_PREFIX}/lib/urdfdom_headers/cmake \
        -Dconsole_bridge_DIR=${URDF_PREFIX}/lib/console_bridge/cmake \
        -Dtinyxml2_DIR=${URDF_PREFIX}/CMake \
        -DTinyXML2_DIR=${URDF_PREFIX}/CMake \
        -DCMAKE_PREFIX_PATH="${URDF_PREFIX};${URDF_PREFIX}/CMake;${URDF_PREFIX}/lib/cmake/tinyxml2;${PACKAGE_DIR}/vsg" \
        -DCMAKE_LIBRARY_PATH=${CUDA_STUBS} \
        -DUSE_CUDA_NVRTC=ON \
        -DNUMPY_INCLUDE_DIR=${NUMPY_INC} \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
ninja && ninja install || { echo "Build failed!"; exit 1; }

# Export VSG_FILE_PATH for convenience
export VSG_FILE_PATH="${VSG_FILE_PATH}"
if ! grep -q "VSG_FILE_PATH" "${HOME}/.bashrc" 2>/dev/null; then
    echo "export VSG_FILE_PATH=\"${VSG_FILE_PATH}\"" >> "${HOME}/.bashrc"
fi

echo "Chrono build in persistent mount directory completed successfully!"
