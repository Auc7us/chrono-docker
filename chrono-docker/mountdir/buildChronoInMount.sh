#!/usr/bin/env bash
set -euo pipefail

ROS_DISTRO=${ROS_DISTRO:-humble}
PACKAGE_DIR=${PACKAGE_DIR:-"$HOME/mountdir/packages"}
INSTALL_PREFIX=${INSTALL_PREFIX:-"$HOME/mountdir/lib/chrono-build"}
VSG_FILE_PATH="${PACKAGE_DIR}/vsg/share/vsgExamples"
CHRONO_CUDA_ARCHITECTURES=${CHRONO_CUDA_ARCHITECTURES:-89}
BLAZE_VERSION_TAG=${BLAZE_VERSION_TAG:-v3.8.2}
DEFAULT_BLAZE_INCLUDE_DIR=/usr/local/include
LOCAL_BLAZE_INCLUDE_DIR="${PACKAGE_DIR}/blaze-3.8.2"
BLAZE_INCLUDE_DIR=${BLAZE_INCLUDE_DIR:-${LOCAL_BLAZE_INCLUDE_DIR}}
URDF_PREFIX="${PACKAGE_DIR}/urdf"
VSG_PREFIX="${PACKAGE_DIR}/vsg"
OPTIX_ARCHIVE_PATH=${OPTIX_ARCHIVE_PATH:-"/opt/optix-installer/sensor-dep.zip"}
OPTIX_INSTALL_DIR=${OPTIX_INSTALL_DIR:-"/opt/optix"}

die() {
    echo "Error: $*" >&2
    exit 1
}

has_blaze_headers() {
    local include_dir=$1
    [ -f "${include_dir}/blaze/system/Version.h" ]
}

ensure_blaze_headers() {
    local tmp_blaze
    local archive_path
    local extracted_dir

    if has_blaze_headers "${BLAZE_INCLUDE_DIR}"; then
        echo "Using Blaze headers from ${BLAZE_INCLUDE_DIR}"
        return
    fi

    if [ "${BLAZE_INCLUDE_DIR}" != "${LOCAL_BLAZE_INCLUDE_DIR}" ]; then
        echo "Blaze headers were not found in ${BLAZE_INCLUDE_DIR}; checking persistent and system fallbacks..."
    fi

    if has_blaze_headers "${LOCAL_BLAZE_INCLUDE_DIR}"; then
        BLAZE_INCLUDE_DIR="${LOCAL_BLAZE_INCLUDE_DIR}"
        echo "Using cached Blaze headers from ${BLAZE_INCLUDE_DIR}"
        return
    fi

    if has_blaze_headers "${DEFAULT_BLAZE_INCLUDE_DIR}"; then
        BLAZE_INCLUDE_DIR="${DEFAULT_BLAZE_INCLUDE_DIR}"
        echo "Using Blaze headers from ${BLAZE_INCLUDE_DIR}"
        return
    fi

    command -v git >/dev/null 2>&1 || die "git is required to fetch Blaze headers."
    command -v wget >/dev/null 2>&1 || die "wget is required to fetch Blaze headers."

    tmp_blaze=$(mktemp -d)

    echo "Blaze headers not found. Downloading ${BLAZE_VERSION_TAG} into ${LOCAL_BLAZE_INCLUDE_DIR}..."
    if git clone --depth 1 --branch "${BLAZE_VERSION_TAG}" https://bitbucket.org/blaze-lib/blaze.git "${tmp_blaze}/blaze-src"; then
        extracted_dir="${tmp_blaze}/blaze-src"
    else
        echo "git clone failed; trying the Bitbucket source archive instead..."
        archive_path="${tmp_blaze}/blaze.tar.gz"
        wget "https://bitbucket.org/blaze-lib/blaze/get/${BLAZE_VERSION_TAG}.tar.gz" -O "${archive_path}" || die "Unable to download Blaze ${BLAZE_VERSION_TAG}. Set BLAZE_INCLUDE_DIR to an existing Blaze install if network access is unavailable."
        tar -xzf "${archive_path}" -C "${tmp_blaze}" || die "Downloaded Blaze archive could not be extracted."
        extracted_dir=$(find "${tmp_blaze}" -maxdepth 1 -mindepth 1 -type d -name 'blaze-lib-blaze-*' | head -n 1)
        [ -n "${extracted_dir}" ] || die "Downloaded Blaze archive did not contain the expected source directory."
    fi

    rm -rf "${LOCAL_BLAZE_INCLUDE_DIR}"
    mkdir -p "${LOCAL_BLAZE_INCLUDE_DIR}"
    cp -R "${extracted_dir}/blaze" "${LOCAL_BLAZE_INCLUDE_DIR}/" || die "Failed to install Blaze headers into ${LOCAL_BLAZE_INCLUDE_DIR}."
    rm -rf "${tmp_blaze}"

    has_blaze_headers "${LOCAL_BLAZE_INCLUDE_DIR}" || die "Blaze headers were downloaded, but blaze/system/Version.h is still missing."

    BLAZE_INCLUDE_DIR="${LOCAL_BLAZE_INCLUDE_DIR}"
    echo "Blaze headers installed to ${BLAZE_INCLUDE_DIR}"
}


ensure_optix_installed() {
    local tmp_optix
    local installer_path

    if [ -f "${OPTIX_INSTALL_DIR}/include/optix.h" ]; then
        echo "Using OptiX installation from ${OPTIX_INSTALL_DIR}"
        return
    fi

    [ -f "${OPTIX_ARCHIVE_PATH}" ] || die "OptiX archive not found at ${OPTIX_ARCHIVE_PATH}. Copy sensor-dep.zip into the image before building."
    command -v unzip >/dev/null 2>&1 || die "unzip is required to extract ${OPTIX_ARCHIVE_PATH}."
    command -v sudo >/dev/null 2>&1 || die "sudo is required to install OptiX into ${OPTIX_INSTALL_DIR}."

    tmp_optix=$(mktemp -d)
    unzip -q "${OPTIX_ARCHIVE_PATH}" -d "${tmp_optix}" || die "Unable to extract ${OPTIX_ARCHIVE_PATH}."
    installer_path=$(find "${tmp_optix}" -maxdepth 2 -type f -name "NVIDIA-OptiX-SDK-*.sh" | head -n 1)
    [ -n "${installer_path}" ] || die "OptiX archive did not contain an NVIDIA-OptiX-SDK installer."

    chmod +x "${installer_path}"
    echo "Installing OptiX from ${OPTIX_ARCHIVE_PATH}..."
    sudo mkdir -p "${OPTIX_INSTALL_DIR}"
    sudo "${installer_path}" --prefix="${OPTIX_INSTALL_DIR}" --skip-license || die "OptiX installer failed."
    rm -rf "${tmp_optix}"

    [ -f "${OPTIX_INSTALL_DIR}/include/optix.h" ] || die "OptiX install completed, but ${OPTIX_INSTALL_DIR}/include/optix.h is still missing."
    echo "OptiX installed to ${OPTIX_INSTALL_DIR}"
}

cd "$(dirname "$0")"
cd chrono

mkdir -p "${PACKAGE_DIR}"

echo "Ensuring Blaze 3.8 headers are present..."
ensure_blaze_headers

echo "Ensuring OptiX is installed..."
ensure_optix_installed

echo "Ensuring URDF dependencies are built..."
if [ ! -d "${PACKAGE_DIR}/urdf" ]; then
    bash contrib/build-scripts/linux/buildURDF.sh "${PACKAGE_DIR}/urdf"
fi

echo "Ensuring VSG dependencies are built..."
if [ ! -f "${VSG_PREFIX}/lib/cmake/vsg/vsgConfig.cmake" ] || \
   [ ! -f "${VSG_PREFIX}/lib/cmake/vsgXchange/vsgXchangeConfig.cmake" ] || \
   [ ! -f "${VSG_PREFIX}/lib/cmake/vsgImGui/vsgImGuiConfig.cmake" ]; then
    rm -rf "${VSG_PREFIX}"
    bash contrib/build-scripts/linux/buildVSG.sh "${VSG_PREFIX}"
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
        -DOptiX_INCLUDE_DIR=${OPTIX_INSTALL_DIR}/include \
        -DOptiX_INSTALL_DIR=${OPTIX_INSTALL_DIR} \
        -Dvsg_DIR=${VSG_PREFIX}/lib/cmake/vsg \
        -DvsgImGui_DIR=${VSG_PREFIX}/lib/cmake/vsgImGui \
        -DvsgXchange_DIR=${VSG_PREFIX}/lib/cmake/vsgXchange \
        -Durdfdom_DIR=${URDF_PREFIX}/lib/urdfdom/cmake \
        -Durdfdom_headers_DIR=${URDF_PREFIX}/lib/urdfdom_headers/cmake \
        -Dconsole_bridge_DIR=${URDF_PREFIX}/lib/console_bridge/cmake \
        -Dtinyxml2_DIR=${URDF_PREFIX}/CMake \
        -DTinyXML2_DIR=${URDF_PREFIX}/CMake \
        -DCMAKE_PREFIX_PATH="${URDF_PREFIX};${URDF_PREFIX}/CMake;${URDF_PREFIX}/lib/cmake/tinyxml2;${VSG_PREFIX}" \
        -DCMAKE_LIBRARY_PATH=${CUDA_STUBS} \
        -DCH_USE_SENSOR_NVRTC=OFF \
        -DNUMPY_INCLUDE_DIR=${NUMPY_INC} \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
ninja && ninja install || { echo "Build failed!"; exit 1; }

# Export VSG_FILE_PATH for convenience
export VSG_FILE_PATH="${VSG_FILE_PATH}"
if ! grep -q "VSG_FILE_PATH" "${HOME}/.bashrc" 2>/dev/null; then
    echo "export VSG_FILE_PATH=\"${VSG_FILE_PATH}\"" >> "${HOME}/.bashrc"
fi

export CHRONO_PYTHONPATH="${INSTALL_PREFIX}/share/chrono/python"
export CHRONO_LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib"
if ! grep -q "${CHRONO_PYTHONPATH}" "${HOME}/.bashrc" 2>/dev/null; then
    echo "export PYTHONPATH=\"${CHRONO_PYTHONPATH}:\$PYTHONPATH\"" >> "${HOME}/.bashrc"
fi
if ! grep -q "${CHRONO_LD_LIBRARY_PATH}" "${HOME}/.bashrc" 2>/dev/null; then
    echo "export LD_LIBRARY_PATH=\"${CHRONO_LD_LIBRARY_PATH}:\$LD_LIBRARY_PATH\"" >> "${HOME}/.bashrc"
fi

echo "Chrono build in persistent mount directory completed successfully!"
