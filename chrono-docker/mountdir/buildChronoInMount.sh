cd chrono
mkdir -p build && cd build
echo "Running cmake..."
cmake ../ -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_DEMOS=ON \
        -DBUILD_BENCHMARKING=OFF \
        -DBUILD_TESTING=OFF \
        -DENABLE_MODULE_VEHICLE=ON \
        -DENABLE_MODULE_VEHICLE_COSIM=OFF \
        -DENABLE_MODULE_IRRLICHT=ON \
        -DENABLE_MODULE_PYTHON=ON \
        -DENABLE_MODULE_SENSOR=ON \
        -DENABLE_MODULE_ROS=ON \
        -DENABLE_MODULE_MULTICORE=ON \
        -DENABLE_MODULE_VSG=OFF \
        -DENABLE_MODULE_PARSERS=OFF \
        -DEigen3_DIR=/usr/lib/cmake/eigen3 \
        -DOptiX_INCLUDE=/opt/optix/include \
        -DOptiX_INSTALL_DIR=/opt/optix \
        -DCMAKE_LIBRARY_PATH=${LIBRARY_PATH} \
        -DUSE_CUDA_NVRTC=ON \
        -DNUMPY_INCLUDE_DIR=$(python3 -c 'import numpy; print(numpy.get_include())') \
        -DCMAKE_INSTALL_PREFIX="$HOME/mountdir/lib/chrono-build"
ninja && ninja install || { echo "Build failed!"; exit 1; }

echo "Chrono build in persistent mount directory completed successfully!"
