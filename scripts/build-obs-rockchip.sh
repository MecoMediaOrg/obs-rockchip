#!/usr/bin/env bash
set -euo pipefail

# Build ffmpeg-rockchip, then OBS Studio as a Debian package linked against the custom FFmpeg.
# Outputs:
#   - ffmpeg install prefix      : $WORKSPACE/install/ffmpeg-rockchip
#   - obs .deb packages/artifacts: $WORKSPACE/build/obs-studio
#
# Supported on Ubuntu/Debian runners. Requires sudo.

WORKSPACE=${WORKSPACE:-"$(pwd)"}
FFMPEG_SRC_DIR=${FFMPEG_SRC_DIR:-"$WORKSPACE/ffmpeg-rockchip"}
MPP_SRC_DIR=${MPP_SRC_DIR:-"$WORKSPACE/mpp"}
RGA_SRC_DIR=${RGA_SRC_DIR:-"$WORKSPACE/rga"}
OBS_SRC_DIR=${OBS_SRC_DIR:-"$WORKSPACE/obs-studio"}
PREFIX_DIR=${PREFIX_DIR:-"$WORKSPACE/install/ffmpeg-rockchip"}
BUILD_DIR=${BUILD_DIR:-"$WORKSPACE/build"}
NUM_JOBS=${NUM_JOBS:-"$(nproc || sysctl -n hw.ncpu)"}
BUILD_TYPE=${BUILD_TYPE:-Release}
RUN_TESTS=${RUN_TESTS:-"0"}
# ccache settings
CCACHE_DIR=${CCACHE_DIR:-"$WORKSPACE/.ccache"}
CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-"10G"}
# Allow opting out
USE_CCACHE=${USE_CCACHE:-"1"}
# Build optimization settings
ENABLE_LTO=${ENABLE_LTO:-"1"}
ENABLE_UNITY_BUILD=${ENABLE_UNITY_BUILD:-"0"}
# Source control settings
FFMPEG_BRANCH=${FFMPEG_BRANCH:-"6.1"}
OBS_VERSION=${OBS_VERSION:-"32.0.0"}

mkdir -p "$PREFIX_DIR" "$BUILD_DIR"

log() {
  echo "[build-obs-rockchip] $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

install_deps() {
  local id
  id=$(detect_distro)
  log "Detected distro: $id"

  case "$id" in
    ubuntu|debian)
      # Update package lists
      sudo apt-get update
      
      # Install essential packages first
      sudo apt-get install -y --no-install-recommends software-properties-common
      sudo add-apt-repository -y universe || true
      sudo add-apt-repository -y multiverse || true
      # Ensure modern CMake (>=3.28). Ubuntu 24.04 has >=3.28 already; on older distros, add Kitware APT.
      if ! cmake --version >/dev/null 2>&1 || ! cmake -P <(printf "string(REGEX MATCH \\\"[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\" v ${CMAKE_VERSION}); if(v VERSION_LESS 3.28.0) message(FATAL_ERROR) "); then
        . /etc/os-release || true
        CODENAME=${UBUNTU_CODENAME:-"noble"}
        sudo apt-get install -y --no-install-recommends ca-certificates gnupg
        sudo rm -f /usr/share/keyrings/kitware-archive-keyring.gpg || true
        curl -fsSL https://apt.kitware.com/keys/kitware-archive-latest.asc | sudo gpg --dearmor -o /usr/share/keyrings/kitware-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ $CODENAME main" | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null
        sudo apt-get update
      fi
      # Build tools (required)
      sudo apt-get install -y --no-install-recommends \
        build-essential cmake extra-cmake-modules ninja-build pkg-config \
        git curl ccache python3 python3-pip zlib1g-dev yasm nasm autoconf \
        automake libtool checkinstall libssl-dev libdrm-dev libx264-dev \
        libx265-dev libv4l-dev libvpx-dev libx11-dev libxext-dev libxfixes-dev \
        libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev libxcb-randr0-dev \
        libxcb-xinerama0-dev libxcb-composite0-dev libxcb-xinput-dev libxcomposite-dev libxinerama-dev libgl1-mesa-dev \
        libglvnd-dev libgles2-mesa-dev libasound2-dev libpulse-dev \
        libx11-xcb-dev \
        libfreetype6-dev libfontconfig1-dev libjansson-dev libmbedtls-dev \
        libcurl4-openssl-dev libudev-dev libpci-dev swig libcmocka-dev \
        libpipewire-0.3-dev libqrcodegencpp-dev uthash-dev libva-dev \
        libspeexdsp-dev libsrt-openssl-dev qt6-base-dev qt6-base-private-dev qt6-wayland \
        qt6-image-formats-plugins fakeroot debhelper devscripts equivs libsimde-dev \
        libxss-dev libdbus-1-dev nlohmann-json3-dev libwebsocketpp-dev libasio-dev \
        libvulkan-dev libzstd-dev libb2-dev libsrtp2-1 libusrsctp2 libvlc-dev \
        meson
      # Optional vendor SDKs (best-effort)
      # libajantv2-dev installed manually from Debian multimedia repository
      # Optional packages (best-effort; may not exist in minimal images)
      sudo apt-get install -y --no-install-recommends librist-dev || true
      # sudo apt-get install -y --no-install-recommends libvpl-dev || true #Not available on arm64
      sudo apt-get install -y --no-install-recommends qt6-svg-dev || true
      
      # Download external dependencies in parallel
      log "Downloading external dependencies in parallel..."
      (
        # Download libdatachannel packages
        if [[ ! -f /tmp/libdatachannel0.23.deb ]]; then
          wget -q https://www.deb-multimedia.org/pool/main/libd/libdatachannel-dmo/libdatachannel0.23_0.23.1-dmo1_arm64.deb -O /tmp/libdatachannel0.23.deb || true
        fi
        if [[ ! -f /tmp/libdatachannel-dev.deb ]]; then
          wget -q https://www.deb-multimedia.org/pool/main/libd/libdatachannel-dmo/libdatachannel-dev_0.23.1-dmo1_arm64.deb -O /tmp/libdatachannel-dev.deb || true
        fi
      ) &
      
      (
        # Download CEF in parallel
        if [[ ! -f /tmp/cef.tar.bz2 ]]; then
          wget -q https://cef-builds.spotifycdn.com/cef_binary_140.1.14%2Bgeb1c06e%2Bchromium-140.0.7339.185_linuxarm64_minimal.tar.bz2 -O /tmp/cef.tar.bz2 || true
        fi
      ) &
      
      # Wait for downloads to complete
      wait
      
      # Install libdatachannel packages
      if [[ -f /tmp/libdatachannel0.23.deb ]]; then
        sudo dpkg -i /tmp/libdatachannel0.23.deb || true
      fi
      if [[ -f /tmp/libdatachannel-dev.deb ]]; then
        sudo dpkg -i /tmp/libdatachannel-dev.deb || true
      fi
      
      # Install CEF
      if [[ -f /tmp/cef.tar.bz2 ]]; then
        cd /tmp && tar -xjf cef.tar.bz2 || true
        sudo mkdir -p /usr/local/cef || true
        sudo cp -r cef_binary_140.1.14+geb1c06e+chromium-140.0.7339.185_linuxarm64_minimal/* /usr/local/cef/ || true
      fi
      # Set up CEF CMake configuration for OBS
      sudo mkdir -p /usr/local/cef/lib/cmake/cef || true
      sudo tee /usr/local/cef/lib/cmake/cef/cef-config.cmake > /dev/null << 'EOF'
set(CEF_ROOT "/usr/local/cef")
set(CEF_INCLUDE_DIR "${CEF_ROOT}")
set(CEF_LIB_DIR "${CEF_ROOT}/Release")
set(CEF_LIB_DEBUG_DIR "${CEF_ROOT}/Debug")
set(CEF_BINARY_DIR "${CEF_ROOT}/Release")
set(CEF_BINARY_DEBUG_DIR "${CEF_ROOT}/Debug")
set(CEF_RESOURCE_DIR "${CEF_ROOT}/Resources")
set(CEF_BINARY_FILES
  chrome-sandbox
  libcef.so
  libEGL.so
  libGLESv2.so
  libvk_swiftshader.so
  libvulkan.so.1
  v8_context_snapshot.bin
  vk_swiftshader_icd.json
)
EOF
      sudo apt-get install -f -y || true
      ;;
    *)
      log "Non-Debian distro detected; this script targets Debian-based build hosts."
      ;;
  esac
}

setup_ccache() {
  if [[ "$USE_CCACHE" != "1" ]]; then
    return
  fi
  if command -v ccache >/dev/null 2>&1; then
    log "Enabling ccache at $CCACHE_DIR (max $CCACHE_MAXSIZE)"
    mkdir -p "$CCACHE_DIR"
    ccache --set-config=cache_dir="$CCACHE_DIR" || true
    ccache --set-config=max_size="$CCACHE_MAXSIZE" || true
    ccache --zero-stats || true
    export CC="ccache gcc"
    export CXX="ccache g++"
    export CUDAHOSTCXX="ccache g++"
    export CCACHE_BASEDIR="$WORKSPACE"
    export CCACHE_SLOPPINESS=time_macros
  else
    log "ccache not found; proceeding without compiler cache"
  fi
}

clone_obs() {
  log "Cloning OBS Studio version $OBS_VERSION"
  require_command git
  
  # Check if OBS is already cloned and on the correct version
  if [[ -d "$OBS_SRC_DIR/.git" ]]; then
    pushd "$OBS_SRC_DIR" >/dev/null
    current_version=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [[ "$current_version" == "$OBS_VERSION" ]]; then
      log "OBS Studio $OBS_VERSION already cloned, skipping"
      popd >/dev/null
      return 0
    fi
    popd >/dev/null
  fi
  
  # Remove existing directory if it exists
  rm -rf "$OBS_SRC_DIR"
  
  # Clone the specific version (tag)
  git clone --depth=1 --branch="$OBS_VERSION" https://github.com/obsproject/obs-studio.git "$OBS_SRC_DIR"
  
  # Initialize and update submodules (required for obs-browser)
  pushd "$OBS_SRC_DIR" >/dev/null
  git submodule update --init --recursive
  popd >/dev/null
  
  pushd "$OBS_SRC_DIR" >/dev/null
  git rev-parse --short HEAD | xargs -I{} bash -c 'echo "[build-obs-rockchip] OBS Studio @ {} (version ${OBS_VERSION})"'
  popd >/dev/null
}

clone_ffmpeg_rockchip() {
  log "Cloning ffmpeg-rockchip branch $FFMPEG_BRANCH"
  require_command git
  
  # Check if ffmpeg-rockchip is already cloned and on the correct branch
  if [[ -d "$FFMPEG_SRC_DIR/.git" ]]; then
    pushd "$FFMPEG_SRC_DIR" >/dev/null
    current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    if [[ "$current_branch" == "$FFMPEG_BRANCH" ]]; then
      log "ffmpeg-rockchip branch $FFMPEG_BRANCH already cloned, skipping"
      popd >/dev/null
      return 0
    fi
    popd >/dev/null
    # Only remove if on wrong branch
    log "ffmpeg-rockchip on wrong branch ($current_branch vs $FFMPEG_BRANCH), removing"
    rm -rf "$FFMPEG_SRC_DIR"
  fi
  
  # Clone the specific branch
  git clone --depth=1 --branch="$FFMPEG_BRANCH" https://github.com/nyanmisaka/ffmpeg-rockchip.git "$FFMPEG_SRC_DIR"
  
  pushd "$FFMPEG_SRC_DIR" >/dev/null
  git rev-parse --short HEAD | xargs -I{} bash -c 'echo "[build-obs-rockchip] ffmpeg-rockchip @ {} (branch ${FFMPEG_BRANCH})"'
  popd >/dev/null
}

build_mpp() {
  log "Building Rockchip MPP into $PREFIX_DIR"
  require_command git
  require_command cmake
  require_command make

  # Check if MPP is already built and installed
  if [[ -f "$PREFIX_DIR/lib/pkgconfig/rockchip_mpp.pc" ]] && pkg-config --exists rockchip_mpp; then
    log "MPP already built and installed, skipping build"
    export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig:$PREFIX_DIR/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
    return 0
  fi

  if [[ ! -d "$MPP_SRC_DIR/.git" ]]; then
    log "Cloning MPP repository..."
    git clone -b jellyfin-mpp --depth=1 https://github.com/nyanmisaka/mpp.git "$MPP_SRC_DIR"
  fi

  pushd "$MPP_SRC_DIR" >/dev/null
  mkdir -p rkmpp_build && cd rkmpp_build
  
  # Configure with the correct options from your example
  cmake \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TEST=OFF \
    ..
  
  make -j"$NUM_JOBS"
  make install
  popd >/dev/null

  # Export for downstream discovery
  export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig:$PREFIX_DIR/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"

  if ! pkg-config --exists rockchip_mpp; then
    log "rockchip_mpp.pc not found in PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
    log "Listing possible pkgconfig dirs:"
    ls -la "$PREFIX_DIR/lib" || true
    ls -la "$PREFIX_DIR/lib/pkgconfig" || true
    ls -la "$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig" || true
    ls -la "$PREFIX_DIR/lib/x86_64-linux-gnu/pkgconfig" || true
    echo "ERROR: rockchip_mpp pkg-config not found after MPP install" >&2
    exit 1
  fi
}

build_rga() {
  log "Building Rockchip RGA into $PREFIX_DIR"
  require_command git
  require_command meson
  require_command ninja

  # Check if RGA is already built and installed
  if [[ -f "$PREFIX_DIR/lib/pkgconfig/librga.pc" ]] && pkg-config --exists librga; then
    log "RGA already built and installed, skipping build"
    export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig:$PREFIX_DIR/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
    return 0
  fi

  if [[ ! -d "$RGA_SRC_DIR/.git" ]]; then
    log "Cloning RGA repository..."
    git clone -b jellyfin-rga --depth=1 https://github.com/nyanmisaka/rk-mirrors.git "$RGA_SRC_DIR"
  fi

  pushd "$RGA_SRC_DIR" >/dev/null
  # Setup meson build directory
  meson setup rkrga_build \
    --prefix="$PREFIX_DIR" \
    --libdir=lib \
    --buildtype=release \
    --default-library=shared \
    -Dcpp_args=-fpermissive \
    -Dlibdrm=false \
    -Dlibrga_demo=false
  
  meson configure rkrga_build
  ninja -C rkrga_build install
  popd >/dev/null

  # Export for downstream discovery
  export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig:$PREFIX_DIR/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"

  if ! pkg-config --exists librga; then
    log "librga.pc not found in PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
    log "Listing possible pkgconfig dirs:"
    ls -la "$PREFIX_DIR/lib" || true
    ls -la "$PREFIX_DIR/lib/pkgconfig" || true
    ls -la "$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig" || true
    ls -la "$PREFIX_DIR/lib/x86_64-linux-gnu/pkgconfig" || true
    echo "ERROR: librga pkg-config not found after RGA install" >&2
    exit 1
  fi
}

build_ffmpeg_rockchip() {
  log "Building ffmpeg-rockchip from $FFMPEG_SRC_DIR"
  require_command gcc
  require_command make

  # Check if ffmpeg is already built and installed
  if [[ -f "$PREFIX_DIR/bin/ffmpeg" ]] && [[ -f "$PREFIX_DIR/lib/pkgconfig/libavcodec.pc" ]]; then
    log "ffmpeg-rockchip already built and installed, skipping build"
    export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
    export PATH="$PREFIX_DIR/bin:$PATH"
    return 0
  fi

  pushd "$FFMPEG_SRC_DIR" >/dev/null

  # Ensure submodules if any (following common FFmpeg fork patterns)
  if [[ -f .gitmodules ]]; then
    git submodule update --init --recursive
  fi

  # Ensure we are on the requested branch/tag (defaults to 6.1 for OBS compatibility)
  if [[ -d .git ]]; then
    log "Checking out ffmpeg-rockchip branch/tag: ${FFMPEG_BRANCH}"
    git fetch --tags --all --prune || true
    if git rev-parse --verify --quiet "origin/${FFMPEG_BRANCH}" >/dev/null; then
      git checkout -f "${FFMPEG_BRANCH}" || git checkout -f "origin/${FFMPEG_BRANCH}"
    else
      git checkout -f "${FFMPEG_BRANCH}" || true
    fi
    git rev-parse --short HEAD | xargs -I{} bash -c 'echo "[build-obs-rockchip] ffmpeg-rockchip @ {} (branch ${FFMPEG_BRANCH})"'
  fi

  # Ensure rockchip_mpp and librga are visible to pkg-config
  if ! pkg-config --exists rockchip_mpp; then
    echo "ERROR: rockchip_mpp not found using pkg-config (PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-})" >&2
    exit 1
  fi
  
  if ! pkg-config --exists librga; then
    echo "ERROR: librga not found using pkg-config (PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-})" >&2
    exit 1
  fi

  # Configure per ffmpeg-rockchip wiki guidance; enable RKMPP, RGA and common codecs OBS expects
  CONFIGURE_FLAGS=(
    --prefix="$PREFIX_DIR"
    --enable-gpl
    --enable-version3
    --enable-nonfree
    --enable-libx264
    --enable-libx265
    --enable-libvpx
    --enable-libdrm
    --enable-libv4l2
    --enable-openssl
    --enable-rkmpp
    --enable-rkrga
    --extra-cflags="-I$PREFIX_DIR/include"
    --extra-ldflags="-L$PREFIX_DIR/lib"
    --enable-shared
    --disable-static
  )
  
  # Add optimization flags for Release builds
  if [[ "$BUILD_TYPE" == "Release" ]]; then
    CONFIGURE_FLAGS+=(
      --extra-cflags="-O3 -march=native"
      --extra-ldflags="-Wl,--as-needed"
    )
  fi
  
  ./configure "${CONFIGURE_FLAGS[@]}"

  # Ensure make uses ccache-wrapped compilers if enabled
  if [[ "$USE_CCACHE" == "1" && -n "${CC:-}" ]]; then
    export PATH="$(dirname $(command -v ccache)):$PATH"
  fi

  make -j"$NUM_JOBS"
  make install
  popd >/dev/null

  # Provide pkg-config hints for OBS
  export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
  export PATH="$PREFIX_DIR/bin:$PATH"

  # If the installed ffversion.h does not expose a numeric major.minor, normalize it to 6.1
  # This addresses OBS's FFmpeg version check when forks emit commit hashes.
  local ffver_h
  ffver_h="$PREFIX_DIR/include/libavutil/ffversion.h"
  if [[ -f "$ffver_h" ]]; then
    if ! grep -E '^[[:space:]]*#define[[:space:]]+FFMPEG_VERSION[[:space:]]+"n?[0-9]+\.[0-9]+' "$ffver_h" >/dev/null 2>&1; then
      sed -i 's/^\([[:space:]]*#define[[:space:]]\+FFMPEG_VERSION[[:space:]]\+\).*/\1"6.1"/' "$ffver_h" || true
      log "Normalized FFMPEG_VERSION in installed headers to 6.1 for OBS compatibility"
    fi
  fi
}

configure_obs_deps() {
  log "Installing OBS Debian build dependencies via mk-build-deps"
  pushd "$OBS_SRC_DIR" >/dev/null
  if [[ -f debian/control ]]; then
    sudo mk-build-deps -ir -t "apt-get -y" debian/control
  else
    log "debian/control not found; installing a minimal dependency set from wiki"
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev \
      libavutil-dev libswresample-dev libswscale-dev libx264-dev \
      libcurl4-openssl-dev libmbedtls-dev libgl1-mesa-dev libjansson-dev \
      libluajit-5.1-dev python3-dev libx11-dev libxcb-randr0-dev \
      libxcb-shm0-dev libxcb-xinerama0-dev libxcb-composite0-dev \
      libxcb-xinput-dev libxcomposite-dev libxinerama-dev libxcb1-dev libx11-xcb-dev \
      libxcb-xfixes0-dev swig libcmocka-dev libxss-dev libglvnd-dev \
      libgles2-mesa-dev libwayland-dev libpci-dev libpipewire-0.3-dev \
      libqrcodegencpp-dev uthash-dev libsimde-dev libspeexdsp-dev \
      libdbus-1-dev nlohmann-json3-dev libwebsocketpp-dev libasio-dev \
      libvulkan-dev libzstd-dev libb2-dev libsrtp2-1 libusrsctp2 libvlc-dev || true
  fi
  popd >/dev/null
}

build_obs() {
  log "Configuring and building OBS against custom FFmpeg"
  local obs_build
  obs_build="$BUILD_DIR/obs-studio"
  rm -rf "$obs_build"
  mkdir -p "$obs_build"

  pushd "$obs_build" >/dev/null

  # Help CMake find SIMDe if installed from distro packages
  SIMDE_HINT=""
  if [[ -f /usr/include/simde/simde-common.h ]]; then
    SIMDE_HINT="-DSIMDe_INCLUDE_DIR=/usr/include"
  fi

  if [[ "$USE_CCACHE" == "1" && -n "${CC:-}" ]]; then
    CMAKE_LAUNCHERS=(
      -DCMAKE_C_COMPILER_LAUNCHER=ccache
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    )
  else
    CMAKE_LAUNCHERS=()
  fi

  # Build optimization flags
  CMAKE_OPTIMIZATIONS=()
  if [[ "$ENABLE_LTO" == "1" ]]; then
    CMAKE_OPTIMIZATIONS+=(-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON)
  fi
  if [[ "$ENABLE_UNITY_BUILD" == "1" ]]; then
    CMAKE_OPTIMIZATIONS+=(-DCMAKE_UNITY_BUILD=ON)
  fi


  cmake -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DUNIX_STRUCTURE=ON \
    -DENABLE_PIPEWIRE=ON \
    -DENABLE_WAYLAND=ON \
    -DENABLE_QT6=ON \
    -DENABLE_AJA=OFF \
    -DFFMPEG_ROOT="$PREFIX_DIR" \
    -DCMAKE_PREFIX_PATH="$PREFIX_DIR" \
    -DCMAKE_C_FLAGS="-D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE" \
    -DCMAKE_CXX_FLAGS="-D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE" \
    ${CMAKE_OPTIMIZATIONS[@]:-} \
    ${CMAKE_LAUNCHERS[@]:-} \
    ${SIMDE_HINT} \
    "$OBS_SRC_DIR"

  ninja -j"$NUM_JOBS"

  if [[ "$RUN_TESTS" == "1" ]]; then
    ctest --output-on-failure -j"$NUM_JOBS"
  fi

  if command -v ccache >/dev/null 2>&1; then
    ccache --show-stats || true
  fi

  log "Building Debian packages"
  # Use CPack to generate debs
  cpack -G DEB

  popd >/dev/null

  log "Artifacts located under $WORKSPACE"
}

package_artifacts() {
  log "Collecting artifacts"
  local out
  out="$WORKSPACE/artifacts"
  rm -rf "$out" && mkdir -p "$out"
  # CPack generates .deb files in the build directory
  local obs_build="$BUILD_DIR/obs-studio"
  shopt -s nullglob
  for f in "$obs_build"/*.deb; do
    cp -v "$f" "$out/"
  done
  # Also check workspace root for any .deb files (fallback)
  for f in "$WORKSPACE"/*.deb; do
    cp -v "$f" "$out/"
  done
  # Include build logs if present
  shopt -s nullglob
  for f in "$WORKSPACE"/*.build "$WORKSPACE"/*.changes "$WORKSPACE"/*.dsc; do
    [[ -f "$f" ]] && cp -v "$f" "$out/" || true
  done
}

main() {
  install_deps
  clone_obs
  clone_ffmpeg_rockchip
  build_mpp
  build_rga
  build_ffmpeg_rockchip
  configure_obs_deps
  build_obs
  package_artifacts
}

main "$@"


