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

# Minimum CMake for the SCM GPU backend on NVIDIA.
#
# cmake/ChronoGPUDetect.cmake only requests the HIP platform when CMake is at least this
# new, because CMAKE_HIP_PLATFORM=nvidia needs 3.28. Below it the ROCm search is skipped
# entirely, so a perfectly good /opt/rocm goes unused and SCM GPU resolves to NONE.
CHRONO_MIN_CMAKE_VERSION=3.28

# Checked here rather than left to verify_configuration, which runs after a full
# configure and can only report the symptom ("no HIP toolchain found") -- wording that
# sends you looking at ROCm when ROCm was never the problem. The image pins cmake 4.4.0
# into /usr/local/bin; this catches a stale image, or a PATH that puts the apt cmake
# (3.22.1 on Ubuntu 22.04) first, in about a second.
verify_cmake_version() {
    local version
    command -v cmake >/dev/null 2>&1 || die "cmake not found on PATH."
    version=$(cmake --version | head -n 1 | awk '{print $3}')

    if [ "$(printf '%s\n%s\n' "${CHRONO_MIN_CMAKE_VERSION}" "${version}" | sort -V | head -n 1)" \
         != "${CHRONO_MIN_CMAKE_VERSION}" ]; then
        echo "  Found cmake ${version} at $(command -v cmake)." >&2
        echo "  The SCM GPU backend needs >= ${CHRONO_MIN_CMAKE_VERSION} on NVIDIA: below that," >&2
        echo "  Chrono never searches for HIP and the terrain silently runs on the CPU." >&2
        echo "  Chrono's own cmake_minimum_required is 3.18, so cmake will NOT complain." >&2
        die "cmake ${version} is too old (need >= ${CHRONO_MIN_CMAKE_VERSION})."
    fi

    echo "Using cmake ${version} from $(command -v cmake)."
}

# Assert that CMake resolved what we asked for. Run from the build directory, after
# cmake and before ninja, so a misconfiguration costs seconds instead of a full build.
#
# Two different signals are needed, because the two failure modes leave different traces:
#
#  - Modules that cannot satisfy their dependencies write OFF back to the cache with
#    FORCE (see src/chrono_synchrono/CMakeLists.txt), so re-reading the cache after
#    configure catches them. They only print a message, which scrolls past in a long
#    configure and leaves a build that succeeds while missing the module.
#
#  - The SCM GPU feature leaves no cache trace at all. CH_ENABLE_VEHICLE_SCM_GPU is the
#    request, not the result: it stays ON even when no HIP toolchain is found and the
#    feature resolves to NONE. The generated CHRONO_HAS_SCM_GPU define is the only
#    reliable evidence that it actually resolved, so check the header, not the cache.
verify_configuration() {
    local failed=0 m

    for m in VEHICLE SENSOR ROS PYTHON SYNCHRONO; do
        if ! grep -qx "CH_ENABLE_MODULE_${m}:BOOL=ON" CMakeCache.txt; then
            echo "  FAIL: CH_ENABLE_MODULE_${m} was requested ON but did not stay ON." >&2
            failed=1
        fi
    done

    if ! grep -qE "^#define CHRONO_HAS_SCM_GPU" chrono_vehicle/ChConfigVehicle.h 2>/dev/null; then
        echo "  FAIL: SCM GPU resolved to NONE -- no HIP toolchain found." >&2
        echo "        The SCM kernels are HIP-only; on NVIDIA they still need ROCm's HIP" >&2
        echo "        headers. Terrain would silently run on the CPU." >&2
        echo "        Check the configure log for 'Searching for HIP'. If it never appeared," >&2
        echo "        the ROCm search was skipped rather than failing, which points at the" >&2
        echo "        CMake version (see verify_cmake_version) and not at ROCm." >&2
        failed=1
    fi

    [ ${failed} -eq 0 ] || die "CMake did not resolve the requested configuration (see above)."
    echo "Configuration verified: all requested modules enabled, SCM GPU resolved."
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

# Keep build output out of "git status" in the Chrono clone.
#
# buildURDF.sh and buildVSG.sh clone and build their dependencies into download_urdf/ and
# download_vsg/ at the source root. Chrono's committed .gitignore covers build/ but not
# those two, so they sit there as untracked directories -- thousands of files that a
# git add -A would happily stage. This clone is also where upstream contributions are
# prepared, which makes that a live hazard rather than a cosmetic one.
#
# .git/info/exclude rather than .gitignore: these are artifacts of how this container
# builds Chrono, not a property of the project, so the rule belongs to the clone and must
# never end up in a commit. Appended idempotently; an existing exclude file is preserved.
ensure_local_git_excludes() {
    local exclude_file=".git/info/exclude"
    local entry

    [ -d .git ] || return 0

    mkdir -p "$(dirname "${exclude_file}")"
    for entry in download_urdf/ download_vsg/; do
        if ! grep -qxF "${entry}" "${exclude_file}" 2>/dev/null; then
            printf '%s\n' "${entry}" >> "${exclude_file}"
        fi
    done
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

# Removed: patch_multicore_thrust_header.
#
# It worked around Thrust 3.x / CUDA 13 fallout in src/chrono/multicore_math/thrust.h.
# Upstream has since absorbed the real fix: the header now includes <iterator> with a
# comment naming std::distance / std::advance / std::iterator_traits as the reason, and
# Thrust_Expand() uses the std:: forms rather than thrust::iterator_difference. Two of
# the three patch blocks were already no-ops against that tree; the third kept injecting
# <thrust/distance.h> and <thrust/advance.h>, which nothing in the file uses any more.
#
# Removed: patch_python_fea_swig_flags.
#
# Not because it was unnecessary -- the flag is load-bearing, ~19 .i files gate content
# on "#ifdef CHRONO_FEA" and without it PyChrono loses its FEA bindings silently -- but
# because it does not need to be a source patch. CMAKE_SWIG_FLAGS is append-only in
# chrono_python/CMakeLists.txt (every touch is set(... "${CMAKE_SWIG_FLAGS};...") or
# list(APPEND ...), never a reset), so seeding it from the cmake command line reaches the
# same place with a dirty working tree. See the -DCMAKE_SWIG_FLAGS argument below.
#
# Both patches modified files tracked by the Chrono repo, which is a hazard when this
# same clone is used to prepare upstream contributions: a git commit -a or git add -A
# sweeps them into a branch. Keeping the tree clean is the point.

cd "$(dirname "$0")"
cd chrono

FMU_FORGE_DIR=${FMU_FORGE_DIR:-"$(pwd)/src/chrono_thirdparty/fmu-forge"}

ensure_fmu_forge_available() {
    local default_fmu_forge_dir

    default_fmu_forge_dir="$(pwd)/src/chrono_thirdparty/fmu-forge"

    if [ -f "${FMU_FORGE_DIR}/fmi2/FmuForgeImport.h" ]; then
        echo "Using fmu-forge from ${FMU_FORGE_DIR}"
        return
    fi

    if [ "${FMU_FORGE_DIR}" != "${default_fmu_forge_dir}" ]; then
        die "fmu-forge headers were not found in FMU_FORGE_DIR=${FMU_FORGE_DIR}."
    fi

    command -v git >/dev/null 2>&1 || die "git is required to initialize the fmu-forge submodule."

    echo "fmu-forge headers not found. Initializing Chrono fmu-forge submodule..."
    git submodule update --init --recursive src/chrono_thirdparty/fmu-forge || die "Unable to initialize fmu-forge submodule."

    [ -f "${FMU_FORGE_DIR}/fmi2/FmuForgeImport.h" ] || die "fmu-forge submodule initialized, but fmi2/FmuForgeImport.h is still missing."
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

ensure_local_git_excludes

echo "Ensuring OptiX is installed..."
ensure_optix_installed

echo "Ensuring URDF dependencies are built..."
if [ ! -d "${PACKAGE_DIR}/urdf" ]; then
    bash contrib/build-scripts/linux/buildURDF.sh "${PACKAGE_DIR}/urdf"
fi

echo "Ensuring VSG dependencies are built..."
# Patched only when VSG is actually about to be built. It used to run unconditionally,
# which left contrib/build-scripts/linux/buildVSG.sh modified on every run even though
# the build below is skipped whenever VSG is already installed -- a tracked file dirtied
# for nothing, in a clone that is also used to prepare upstream contributions.
if [ ! -f "${VSG_PREFIX}/lib/cmake/vsg/vsgConfig.cmake" ] || \
   [ ! -f "${VSG_PREFIX}/lib/cmake/vsgXchange/vsgXchangeConfig.cmake" ] || \
   [ ! -f "${VSG_PREFIX}/lib/cmake/vsgImGui/vsgImGuiConfig.cmake" ]; then
    patch_vsg_build_script
    rm -rf "${VSG_PREFIX}"
    bash contrib/build-scripts/linux/buildVSG.sh "${VSG_PREFIX}"
fi

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

verify_cmake_version

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
        -DOptiX_INCLUDE=${OPTIX_INSTALL_DIR}/include \
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
        -DCMAKE_SWIG_FLAGS="-DCHRONO_FEA" \
        -DNUMPY_INCLUDE_DIR=${NUMPY_INC} \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"

echo "Verifying CMake resolved the requested configuration..."
verify_configuration

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
