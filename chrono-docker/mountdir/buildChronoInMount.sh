#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Build Project Chrono with the AMD HIP/ROCm backend -- FULL module set, Sensor
# excluded (Chrono::Sensor needs NVIDIA OptiX, which has no HIP equivalent).
#
# Host compiler is g++-13 (Ubuntu 22.04's default g++-11 lacks _Float16, needed
# by ROCm 7.x rocThrust). This matches the Chrono dev's working AMD build. The
# few host .cpp that get the HIP device thrust path AND DEM's PUBLIC
# __HIP_PLATFORM_AMD__ must be compiled by the ROCm clang instead -- those are
# marked LANGUAGE HIP via the patch_*_hip_language step below.
#
# GPU arch defaults to gfx90a (MI210); override CHRONO_HIP_ARCHITECTURES for
# other accelerators (e.g. gfx942 for MI300X).
# -----------------------------------------------------------------------------

ROS_DISTRO=${ROS_DISTRO:-humble}
PACKAGE_DIR=${PACKAGE_DIR:-"$HOME/mountdir/packages"}
INSTALL_PREFIX=${INSTALL_PREFIX:-"$HOME/mountdir/lib/chrono-build"}
export VSG_FILE_PATH="${PACKAGE_DIR}/vsg/share/vsgExamples"
CHRONO_HIP_ARCHITECTURES=${CHRONO_HIP_ARCHITECTURES:-gfx90a}
NINJA_FLAGS=${NINJA_FLAGS:-}
BLAZE_VERSION_TAG=${BLAZE_VERSION_TAG:-v3.8.2}
DEFAULT_BLAZE_INCLUDE_DIR=/usr/local/include
LOCAL_BLAZE_INCLUDE_DIR="${PACKAGE_DIR}/blaze-3.8.2"
BLAZE_INCLUDE_DIR=${BLAZE_INCLUDE_DIR:-${LOCAL_BLAZE_INCLUDE_DIR}}
URDF_PREFIX="${PACKAGE_DIR}/urdf"
VSG_PREFIX="${PACKAGE_DIR}/vsg"
FMU_FORGE_DIR=${FMU_FORGE_DIR:-}

# Host C/C++ compiler -- g++-13 (see note above).
HOST_CC=${HOST_CC:-gcc-13}
HOST_CXX=${HOST_CXX:-g++-13}

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

patch_hip_language_sources() {
    # A few host .cpp hit the HIP device-thrust path while also receiving DEM's
    # PUBLIC __HIP_PLATFORM_AMD__, which makes rocThrust/rocPRIM use AMD GPU
    # builtins g++ cannot compile. Mark those files LANGUAGE HIP so CMake builds
    # them with the ROCm clang instead. Guarded to the HIP backend.
    local tmp_file
    local fsi_cmake="src/chrono_fsi/sph/CMakeLists.txt"
    local veh_cmake="src/chrono_vehicle/cosim/CMakeLists.txt"

    if [ -f "${fsi_cmake}" ] && ! grep -q "ChSphVisualizationVSG.cpp PROPERTIES LANGUAGE HIP" "${fsi_cmake}"; then
        tmp_file=$(mktemp)
        awk '
            /add_library\(Chrono_fsisph_vsg/ && !done {
                print "    if(DEFINED CHRONO_GPU_BACKEND AND CHRONO_GPU_BACKEND STREQUAL \"HIP\")"
                print "      set_source_files_properties(visualization/ChSphVisualizationVSG.cpp PROPERTIES LANGUAGE HIP)"
                print "    endif()"
                print ""
                done = 1
            }
            { print }
        ' "${fsi_cmake}" > "${tmp_file}"
        cat "${tmp_file}" > "${fsi_cmake}"
        rm -f "${tmp_file}"
    fi

    if [ -f "${veh_cmake}" ] && ! grep -q "ChVehicleCosimTerrainNodeGranularSPH.cpp PROPERTIES LANGUAGE HIP" "${veh_cmake}"; then
        tmp_file=$(mktemp)
        awk '
            /add_library\(Chrono_vehicle_cosim/ && !done {
                print "if(DEFINED CHRONO_GPU_BACKEND AND CHRONO_GPU_BACKEND STREQUAL \"HIP\")"
                print "  set_source_files_properties(terrain/ChVehicleCosimTerrainNodeGranularSPH.cpp PROPERTIES LANGUAGE HIP)"
                print "endif()"
                print ""
                done = 1
            }
            { print }
        ' "${veh_cmake}" > "${tmp_file}"
        cat "${tmp_file}" > "${veh_cmake}"
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

echo "Ensuring Chrono multicore/Thrust and Python SWIG patches are applied..."
patch_multicore_thrust_header
patch_python_fea_swig_flags
patch_hip_language_sources

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

# --- ROCm / HIP toolchain + host compiler ------------------------------------
export ROCM_PATH=${ROCM_PATH:-/opt/rocm}
export PATH="${ROCM_PATH}/bin:${PATH}"
command -v hipcc       >/dev/null 2>&1 || die "hipcc not found; ensure the ROCm image provides it."
command -v "${HOST_CXX}" >/dev/null 2>&1 || die "${HOST_CXX} not found; the image must install g++-13."

# CMake 3.22 rejects the hipcc wrapper as CMAKE_HIP_COMPILER, so point it at the
# ROCm clang++ directly (path differs between ROCm 6.x and 7.x layouts). This
# clang is also used to compile the LANGUAGE-HIP-marked host files below.
HIP_CLANG=""
for c in "${ROCM_PATH}/lib/llvm/bin/clang++" "${ROCM_PATH}/llvm/bin/clang++"; do
    [ -x "$c" ] && HIP_CLANG="$c" && break
done
[ -n "${HIP_CLANG}" ] || die "Could not find the ROCm clang++ under ${ROCM_PATH}."

NUMPY_INC=$(python3 - <<'PY'
import numpy
print(numpy.get_include())
PY
)

mkdir -p build && cd build
echo "Running cmake (HIP backend, arch=${CHRONO_HIP_ARCHITECTURES}, host CXX=${HOST_CXX})..."
cmake ../ -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="${HOST_CC}" \
        -DCMAKE_CXX_COMPILER="${HOST_CXX}" \
        -DBUILD_DEMOS=ON \
        -DBUILD_BENCHMARKING=OFF \
        -DBUILD_TESTING=OFF \
        -DCH_ENABLE_MODULE_FEA=ON \
        -DCH_ENABLE_MODULE_VEHICLE=ON \
        -DCH_ENABLE_MODULE_IRRLICHT=ON \
        -DCH_ENABLE_MODULE_PYTHON=ON \
        -DCH_ENABLE_MODULE_SENSOR=OFF \
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
        -DCHRONO_GPU_BACKEND=HIP \
        -DCMAKE_HIP_COMPILER="${HIP_CLANG}" \
        -DCMAKE_HIP_ARCHITECTURES="${CHRONO_HIP_ARCHITECTURES}" \
        -DCHRONO_HIP_ARCHITECTURES="${CHRONO_HIP_ARCHITECTURES}" \
        -Dblaze_INCLUDE_DIR=${BLAZE_INCLUDE_DIR} \
        -DEigen3_DIR=/usr/lib/cmake/eigen3 \
        -DEIGEN3_INCLUDE_DIR=/usr/include/eigen3 \
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
        -DNUMPY_INCLUDE_DIR=${NUMPY_INC} \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
ninja ${NINJA_FLAGS} && ninja ${NINJA_FLAGS} install || {
    echo "Build failed! Re-run with NINJA_FLAGS='-j1 -v' ./buildChronoInMount.sh to show the exact failing command." >&2
    exit 1
}

# --- Runtime environment -----------------------------------------------------
CHRONO_ENV_FILE="${HOME}/mountdir/chrono_env.sh"
mkdir -p "$(dirname "${CHRONO_ENV_FILE}")" "${HOME}/.local/bin"

if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" "${HOME}/.local/bin/python"
fi

cat > "${CHRONO_ENV_FILE}" <<EOF
export PATH="${HOME}/.local/bin\${PATH:+:\${PATH}}"
export PYTHONPATH="${INSTALL_PREFIX}/share/chrono/python\${PYTHONPATH:+:\${PYTHONPATH}}"
export LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib:${VSG_PREFIX}/lib:${URDF_PREFIX}/lib:${ROCM_PATH}/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
export VSG_FILE_PATH="${VSG_FILE_PATH}"
EOF

if ! grep -Fq "source ${CHRONO_ENV_FILE}" "${HOME}/.bashrc" 2>/dev/null; then
    echo "[ -f \"${CHRONO_ENV_FILE}\" ] && source \"${CHRONO_ENV_FILE}\"" >> "${HOME}/.bashrc"
fi

echo "Chrono (HIP/${CHRONO_HIP_ARCHITECTURES}, full module set minus Sensor) installed under ${INSTALL_PREFIX}"
echo "Runtime env file: ${CHRONO_ENV_FILE}"
echo "Build complete!"
