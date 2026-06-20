#!/usr/bin/env bash
set -euo pipefail

ROS_DISTRO=${ROS_DISTRO:-humble}
PACKAGE_DIR=${PACKAGE_DIR:-"$HOME/mountdir/packages"}
INSTALL_PREFIX=${INSTALL_PREFIX:-"$HOME/mountdir/lib/chrono-build"}
VSG_FILE_PATH="${PACKAGE_DIR}/vsg/share/vsgExamples"
CHRONO_CUDA_ARCHITECTURES=${CHRONO_CUDA_ARCHITECTURES:-89}
CHRONO_CUDA_FLAGS=${CHRONO_CUDA_FLAGS:-"--expt-relaxed-constexpr"}
NINJA_FLAGS=${NINJA_FLAGS:-}
BLAZE_VERSION_TAG=${BLAZE_VERSION_TAG:-v3.8.2}
DEFAULT_BLAZE_INCLUDE_DIR=/usr/local/include
LOCAL_BLAZE_INCLUDE_DIR="${PACKAGE_DIR}/blaze-3.8.2"
BLAZE_INCLUDE_DIR=${BLAZE_INCLUDE_DIR:-${LOCAL_BLAZE_INCLUDE_DIR}}
URDF_PREFIX="${PACKAGE_DIR}/urdf"
VSG_PREFIX="${PACKAGE_DIR}/vsg"
OPTIX_ARCHIVE_PATH=${OPTIX_ARCHIVE_PATH:-"/opt/optix-installer/sensor-dep.zip"}
OPTIX_INSTALL_DIR=${OPTIX_INSTALL_DIR:-"${PACKAGE_DIR}/optix"}
FMU_FORGE_DIR=${FMU_FORGE_DIR:-}

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

    tmp_optix=$(mktemp -d)
    unzip -q "${OPTIX_ARCHIVE_PATH}" -d "${tmp_optix}" || die "Unable to extract ${OPTIX_ARCHIVE_PATH}."
    installer_path=$(find "${tmp_optix}" -maxdepth 2 -type f -name "NVIDIA-OptiX-SDK-*.sh" | head -n 1)
    [ -n "${installer_path}" ] || die "OptiX archive did not contain an NVIDIA-OptiX-SDK installer."

    chmod +x "${installer_path}"
    echo "Installing OptiX from ${OPTIX_ARCHIVE_PATH}..."
    if mkdir -p "${OPTIX_INSTALL_DIR}" 2>/dev/null; then
        "${installer_path}" --prefix="${OPTIX_INSTALL_DIR}" --skip-license || die "OptiX installer failed."
    else
        command -v sudo >/dev/null 2>&1 || die "sudo is required to install OptiX into ${OPTIX_INSTALL_DIR}."
        sudo mkdir -p "${OPTIX_INSTALL_DIR}"
        sudo "${installer_path}" --prefix="${OPTIX_INSTALL_DIR}" --skip-license || die "OptiX installer failed."
    fi
    rm -rf "${tmp_optix}"

    [ -f "${OPTIX_INSTALL_DIR}/include/optix.h" ] || die "OptiX install completed, but ${OPTIX_INSTALL_DIR}/include/optix.h is still missing."
    echo "OptiX installed to ${OPTIX_INSTALL_DIR}"
}

patch_vsg_build_script() {
    local script_path="contrib/build-scripts/linux/buildVSG.sh"
    local tmp_file

    [ -f "${script_path}" ] || die "VSG build script not found at ${script_path}."

    if ! grep -q "set -euo pipefail" "${script_path}"; then
        tmp_file=$(mktemp)
        awk 'NR == 1 { print; print "set -euo pipefail"; next } { print }' "${script_path}" > "${tmp_file}"
        cat "${tmp_file}" > "${script_path}"
        rm -f "${tmp_file}"
    fi

    if ! grep -q "GLSLANG_TESTS:BOOL=OFF" "${script_path}"; then
        tmp_file=$(mktemp)
        awk '
            /-DBUILD_SHARED_LIBS:BOOL=\$\{BUILDSHARED\} \\/ {
                print
                print "      -DBUILD_TESTING:BOOL=OFF \\"
                print "      -DGLSLANG_TESTS:BOOL=OFF \\"
                print "      -DSPIRV_SKIP_TESTS:BOOL=ON \\"
                next
            }
            { print }
        ' "${script_path}" > "${tmp_file}"
        cat "${tmp_file}" > "${script_path}"
        rm -f "${tmp_file}"
    fi
}

patch_multicore_thrust_header() {
    local header_path="src/chrono/multicore_math/thrust.h"
    local tmp_file

    [ -f "${header_path}" ] || die "Chrono multicore Thrust header not found at ${header_path}."

    if ! grep -q "#include <iterator>" "${header_path}"; then
        tmp_file=$(mktemp)
        awk '{
            print
            if ($0 == "#include <iostream>") {
                print "#include <iterator>"
            }
        }' "${header_path}" > "${tmp_file}"
        cat "${tmp_file}" > "${header_path}"
        rm -f "${tmp_file}"
    fi

    if ! grep -q "#include <thrust/distance.h>" "${header_path}"; then
        tmp_file=$(mktemp)
        awk '{
            print
            if ($0 == "#include <thrust/copy.h>") {
                print "#include <thrust/distance.h>"
                print "#include <thrust/advance.h>"
            }
        }' "${header_path}" > "${tmp_file}"
        cat "${tmp_file}" > "${header_path}"
        rm -f "${tmp_file}"
    fi

    if grep -q "thrust::iterator_difference" "${header_path}"; then
        sed -i \
            -e 's/typename thrust::iterator_difference<InputIterator1>::type/typename std::iterator_traits<InputIterator1>::difference_type/g' \
            "${header_path}"
    fi
}

patch_python_fea_swig_flags() {
    local cmake_path="src/chrono_swig/chrono_python/CMakeLists.txt"
    local tmp_file

    [ -f "${cmake_path}" ] || die "Chrono Python SWIG CMake file not found at ${cmake_path}."

    if ! grep -q -- "-DCHRONO_FEA" "${cmake_path}"; then
        tmp_file=$(mktemp)
        awk '
            /if\(CH_ENABLE_MODULE_VSG\)/ && ! inserted {
                print "if(CH_ENABLE_MODULE_FEA)"
                print "  set(CMAKE_SWIG_FLAGS \"${CMAKE_SWIG_FLAGS};-DCHRONO_FEA\")"
                print "endif()"
                print ""
                inserted = 1
            }
            { print }
        ' "${cmake_path}" > "${tmp_file}"
        cat "${tmp_file}" > "${cmake_path}"
        rm -f "${tmp_file}"
    fi
}

cd "$(dirname "$0")"
cd chrono

FMU_FORGE_DIR=${FMU_FORGE_DIR:-"$(pwd)/src/chrono_thirdparty/fmu-forge"}

ensure_fmu_forge_available() {
    local default_fmu_forge_dir

    default_fmu_forge_dir="$(pwd)/src/chrono_thirdparty/fmu-forge"

    if [ -f "${FMU_FORGE_DIR}/fmi2/FmuToolsImport.h" ]; then
        echo "Using fmu-forge from ${FMU_FORGE_DIR}"
        return
    fi

    if [ "${FMU_FORGE_DIR}" != "${default_fmu_forge_dir}" ]; then
        die "fmu-forge headers were not found in FMU_FORGE_DIR=${FMU_FORGE_DIR}."
    fi

    command -v git >/dev/null 2>&1 || die "git is required to initialize the fmu-forge submodule."

    echo "fmu-forge headers not found. Initializing Chrono fmu-forge submodule..."
    git submodule update --init --recursive src/chrono_thirdparty/fmu-forge || die "Unable to initialize fmu-forge submodule."

    [ -f "${FMU_FORGE_DIR}/fmi2/FmuToolsImport.h" ] || die "fmu-forge submodule initialized, but fmi2/FmuToolsImport.h is still missing."
}

ensure_flatbuffers_available() {
    local flatbuffers_dir="src/chrono_thirdparty/flatbuffers"
    local flatbuffers_header="${flatbuffers_dir}/include/flatbuffers/flatbuffers.h"

    if [ -f "${flatbuffers_header}" ]; then
        echo "Using FlatBuffers from $(pwd)/${flatbuffers_dir}"
        return
    fi

    command -v git >/dev/null 2>&1 || die "git is required to initialize the flatbuffers submodule."

    echo "FlatBuffers headers not found. Initializing Chrono flatbuffers submodule..."
    git submodule update --init --recursive "${flatbuffers_dir}" || die "Unable to initialize flatbuffers submodule."

    [ -f "${flatbuffers_header}" ] || die "flatbuffers submodule initialized, but include/flatbuffers/flatbuffers.h is still missing."
}

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
patch_vsg_build_script
if [ ! -f "${VSG_PREFIX}/lib/cmake/vsg/vsgConfig.cmake" ] || \
   [ ! -f "${VSG_PREFIX}/lib/cmake/vsgXchange/vsgXchangeConfig.cmake" ] || \
   [ ! -f "${VSG_PREFIX}/lib/cmake/vsgImGui/vsgImGuiConfig.cmake" ]; then
    rm -rf "${VSG_PREFIX}"
    bash contrib/build-scripts/linux/buildVSG.sh "${VSG_PREFIX}"
fi

echo "Ensuring Chrono CUDA 13.2 compatibility patches are applied..."
patch_multicore_thrust_header
patch_python_fea_swig_flags

echo "Ensuring FMI dependencies are present..."
ensure_fmu_forge_available

echo "Ensuring SynChrono dependencies are present..."
ensure_flatbuffers_available

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
        -DCH_ENABLE_MODULE_FEA=ON \
        -DCH_ENABLE_MODULE_VEHICLE=ON \
        -DCH_ENABLE_MODULE_IRRLICHT=ON \
        -DCH_ENABLE_MODULE_PYTHON=ON \
        -DCH_ENABLE_MODULE_SENSOR=ON \
        -DCH_ENABLE_MODULE_ROS=ON \
        -DCH_ENABLE_MODULE_MULTICORE=ON \
        -DCH_ENABLE_MODULE_VSG=ON \
        -DCH_ENABLE_MODULE_PARSERS=ON \
        -DCH_ENABLE_MODULE_DEM=ON \
        -DCH_ENABLE_MODULE_FSI=ON \
        -DCH_ENABLE_MODULE_FSI_SPH=ON \
        -DCH_ENABLE_MODULE_FSI_TDPF=ON \
        -DCH_ENABLE_MODULE_SYNCHRONO=ON \
        -DCH_ENABLE_MODULE_FMI=ON \
        -DCH_ENABLE_MODULE_PERIDYNAMICS=ON \
        -DCHRONO_CUDA_ARCHITECTURES=${CHRONO_CUDA_ARCHITECTURES} \
        -DCMAKE_CUDA_FLAGS="${CHRONO_CUDA_FLAGS}" \
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
        -DFMU_FORGE_DIR="${FMU_FORGE_DIR}" \
        -DCMAKE_PREFIX_PATH="${URDF_PREFIX};${URDF_PREFIX}/CMake;${URDF_PREFIX}/lib/cmake/tinyxml2;${VSG_PREFIX}" \
        -DCMAKE_LIBRARY_PATH=${CUDA_STUBS} \
        -DCH_USE_SENSOR_NVRTC=OFF \
        -DNUMPY_INCLUDE_DIR=${NUMPY_INC} \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
ninja ${NINJA_FLAGS} && ninja ${NINJA_FLAGS} install || {
    echo "Build failed! Re-run with NINJA_FLAGS='-j1 -v' ./buildChronoInMount.sh to show the exact failing command." >&2
    exit 1
}

# Export runtime paths for Python demos and installed Chrono libraries.
CHRONO_ENV_FILE="${HOME}/mountdir/chrono_env.sh"
mkdir -p "$(dirname "${CHRONO_ENV_FILE}")" "${HOME}/.local/bin"

if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" "${HOME}/.local/bin/python"
fi

cat > "${CHRONO_ENV_FILE}" <<EOF
export PATH="${HOME}/.local/bin\${PATH:+:\${PATH}}"
export PYTHONPATH="${INSTALL_PREFIX}/share/chrono/python:${HOME}/mountdir/chrono/build/bin\${PYTHONPATH:+:\${PYTHONPATH}}"
export LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib:${VSG_PREFIX}/lib:${URDF_PREFIX}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
export VSG_FILE_PATH="${VSG_FILE_PATH}"
EOF

if ! grep -Fq "source ${CHRONO_ENV_FILE}" "${HOME}/.bashrc" 2>/dev/null; then
    echo "[ -f \"${CHRONO_ENV_FILE}\" ] && source \"${CHRONO_ENV_FILE}\"" >> "${HOME}/.bashrc"
fi

echo "Chrono runtime environment written to ${CHRONO_ENV_FILE}"
echo "Chrono build in persistent mount directory completed successfully!"
