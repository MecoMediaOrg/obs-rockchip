#!/usr/bin/env bash
set -euo pipefail

# Build ffmpeg-rockchip, then OBS Studio as a Debian package linked against the custom FFmpeg.
# Optimized for GitHub Actions with caching, parallel builds, and CEF integration for obs-browser.
# ARM64-focused build for Rockchip platforms using pre-compiled CEF from OBS Project.

WORKSPACE=${WORKSPACE:-"$(pwd)"}
FFMPEG_SRC_DIR=${FFMPEG_SRC_DIR:-"$WORKSPACE/ffmpeg-rockchip"}
MPP_SRC_DIR=${MPP_SRC_DIR:-"$WORKSPACE/mpp"}
RGA_SRC_DIR=${RGA_SRC_DIR:-"$WORKSPACE/rga"}
OBS_SRC_DIR=${OBS_SRC_DIR:-"$WORKSPACE/obs-studio"}
CEF_ROOT_DIR=${CEF_ROOT_DIR:-"$WORKSPACE/cef"}
PREFIX_DIR=${PREFIX_DIR:-"/usr"}
BUILD_DIR=${BUILD_DIR:-"$WORKSPACE/build"}
NUM_JOBS=${NUM_JOBS:-"$(nproc)"}
BUILD_TYPE=${BUILD_TYPE:-RelWithDebInfo}
RUN_TESTS=${RUN_TESTS:-"0"}
# GitHub Actions optimizations
CCACHE_DIR=${CCACHE_DIR:-"$HOME/.ccache"}
CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-"3G"} # Increased for CEF builds
USE_CCACHE=${USE_CCACHE:-"1"}
ENABLE_LTO=${ENABLE_LTO:-"0"} # Disable LTO for faster CI builds
ENABLE_UNITY_BUILD=${ENABLE_UNITY_BUILD:-"0"} # Disable unity builds
# CEF settings - ARM64 only, using OBS pre-compiled version
CEF_VERSION=${CEF_VERSION:-"6533_linux_aarch64_v6"}
CEF_ARCH="linuxarm64" # Fixed to ARM64 only
CEF_URL="https://cdn-fastly.obsproject.com/downloads/cef_binary_6533_linux_aarch64_v6.tar.xz"
# Source control settings
FFMPEG_BRANCH=${FFMPEG_BRANCH:-"6.1"}
OBS_VERSION=${OBS_VERSION:-"32.0.0"}

mkdir -p "$PREFIX_DIR" "$BUILD_DIR"

log() {
  echo "::group::$*"
  echo "[$(date '+%H:%M:%S')] $*"
}

end_group() {
  echo "::endgroup::"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { 
    echo "::error::Missing required command: $1"; 
    exit 1; 
  }
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
  log "Installing dependencies"
  local id
  id=$(detect_distro)
  
  # Use GitHub Actions runner optimization
  export DEBIAN_FRONTEND=noninteractive
  
  case "$id" in
    ubuntu|debian)
      # Update package lists
      sudo apt-get update -qq
      
      # Core build tools (from FFmpeg guide + OBS requirements)
      sudo apt-get install -y --no-install-recommends \
        autoconf automake build-essential cmake extra-cmake-modules \
        ninja-build pkg-config clang clang-format git-core curl ccache \
        git zsh libtool meson texinfo wget yasm zlib1g-dev checkinstall \
        fakeroot debhelper devscripts equivs
      
      # FFmpeg dependencies (from FFmpeg Ubuntu guide)
      sudo apt-get install -y --no-install-recommends \
        libass-dev libfreetype6-dev libgnutls28-dev libmp3lame-dev \
        libsdl2-dev libva-dev libvdpau-dev libvorbis-dev libxcb1-dev \
        libxcb-shm0-dev libxcb-xfixes0-dev libx264-dev libx265-dev \
        libvpx-dev libfdk-aac-dev libopus-dev libnuma-dev
      
      # Additional FFmpeg libraries for Ubuntu 20.04+
      sudo apt-get install -y --no-install-recommends \
        libunistring-dev libaom-dev libdav1d-dev || true
      
      # OBS Studio specific dependencies
      sudo apt-get install -y --no-install-recommends \
        libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev \
        libavutil-dev libswresample-dev libswscale-dev libcurl4-openssl-dev \
        libmbedtls-dev libgl1-mesa-dev libjansson-dev libluajit-5.1-dev \
        python3-dev libsimde-dev
      
      # X11/Wayland/Graphics
      sudo apt-get install -y --no-install-recommends \
        libx11-dev libxcb-randr0-dev libxcb-shm0-dev libxcb-xinerama0-dev \
        libxcb-composite0-dev libxcomposite-dev libxinerama-dev libxcb1-dev \
        libx11-xcb-dev libxcb-xfixes0-dev swig libcmocka-dev libxss-dev \
        libglvnd-dev libgles2-mesa-dev libwayland-dev librist-dev \
        libsrt-openssl-dev libpci-dev libpipewire-0.3-dev libqrcodegencpp-dev \
        uthash-dev
      
      # CEF/Chromium dependencies - ATK (Accessibility Toolkit)
      sudo apt-get install -y --no-install-recommends \
        libatk1.0-dev libatk-bridge2.0-dev libatspi2.0-dev \
        libatk-adaptor
      
      # CEF/Chromium dependencies - X11 extensions
      sudo apt-get install -y --no-install-recommends \
        libxdamage-dev libxfixes-dev libxrandr-dev libxrender-dev \
        libxext-dev libxmu-dev libxt-dev libxpm-dev
      
      # Qt6 and UI
      sudo apt-get install -y --no-install-recommends \
        qt6-base-dev qt6-base-private-dev qt6-svg-dev qt6-wayland \
        qt6-image-formats-plugins
      
      # Audio/Video processing
      sudo apt-get install -y --no-install-recommends \
        libasound2-dev libfontconfig-dev libfreetype6-dev libjack-jackd2-dev \
        libpulse-dev libsndio-dev libspeexdsp-dev libudev-dev libv4l-dev \
        libva-dev libvlc-dev libdrm-dev nlohmann-json3-dev \
        libwebsocketpp-dev libasio-dev
      
      # Additional build tools
      sudo apt-get install -y --no-install-recommends \
        nasm xz-utils
      
      # Download and install libdatachannel for ARM64
      (
        cd /tmp
        wget -q "https://www.deb-multimedia.org/pool/main/libd/libdatachannel-dmo/libdatachannel0.23_0.23.1-dmo1_arm64.deb" || true
        wget -q "https://www.deb-multimedia.org/pool/main/libd/libdatachannel-dmo/libdatachannel-dev_0.23.1-dmo1_arm64.deb" || true
        
        # Install downloaded packages
        for deb in libdatachannel*.deb; do
          [[ -f "$deb" ]] && sudo dpkg -i "$deb" || true
        done
        
        # Fix any broken dependencies
        sudo apt-get install -f -y || true
      ) &
      
      wait # Wait for background installation
      ;;
    *)
      echo "::error::Unsupported distribution: $id"
      exit 1
      ;;
  esac
  end_group
}

setup_ccache() {
  if [[ "$USE_CCACHE" != "1" ]]; then
    return
  fi
  
  log "Setting up ccache"
  if command -v ccache >/dev/null 2>&1; then
    mkdir -p "$CCACHE_DIR"
    ccache --set-config=cache_dir="$CCACHE_DIR"
    ccache --set-config=max_size="$CCACHE_MAXSIZE"
    ccache --set-config=compression=true
    ccache --set-config=compression_level=6
    ccache --zero-stats
    
    export CC="ccache gcc"
    export CXX="ccache g++"
    export CCACHE_BASEDIR="$WORKSPACE"
    export CCACHE_SLOPPINESS="time_macros,include_file_mtime"
    export CCACHE_COMPILERCHECK=content
    
    echo "::notice::ccache enabled with $(ccache --get-config=cache_dir) (max $(ccache --get-config=max_size))"
  fi
  end_group
}

download_and_setup_cef() {
  log "Setting up pre-compiled CEF for ARM64"
  
  # Check if CEF is already extracted and ready
  if [[ -d "$CEF_ROOT_DIR" && -f "$CEF_ROOT_DIR/Release/libcef.so" && -f "$CEF_ROOT_DIR/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
    echo "::notice::CEF already downloaded and ready, skipping"
    end_group
    return 0
  fi
  
  local cef_archive="$WORKSPACE/cef.tar.xz"
  
  # Download CEF if not already present
  if [[ ! -f "$cef_archive" ]]; then
    echo "::notice::Downloading pre-compiled CEF from $CEF_URL"
    local download_attempts=0
    local max_attempts=3
    
    while [[ $download_attempts -lt $max_attempts ]]; do
      if curl -L -o "$cef_archive" "$CEF_URL"; then
        break
      else
        download_attempts=$((download_attempts + 1))
        echo "::warning::Download attempt $download_attempts failed, retrying..."
        rm -f "$cef_archive"
        sleep 2
      fi
    done
    
    if [[ $download_attempts -eq $max_attempts ]]; then
      echo "::error::Failed to download CEF after $max_attempts attempts from $CEF_URL"
      exit 1
    fi
  fi
  
  # Verify the downloaded file
  echo "::notice::Verifying downloaded CEF archive..."
  if [[ ! -f "$cef_archive" ]]; then
    echo "::error::CEF archive not found: $cef_archive"
    exit 1
  fi
  
  # Check file size (should be substantial for CEF)
  local file_size=$(stat -c%s "$cef_archive" 2>/dev/null || echo "0")
  if [[ "$file_size" -lt 1000000 ]]; then
    echo "::error::CEF archive too small ($file_size bytes), likely corrupted"
    rm -f "$cef_archive"
    exit 1
  fi
  
  # Test if it's a valid xz archive
  if ! xz -t "$cef_archive" 2>/dev/null; then
    echo "::error::CEF archive is not a valid xz file"
    echo "::error::File info: $(file "$cef_archive")"
    rm -f "$cef_archive"
    exit 1
  fi
  
  echo "::notice::CEF archive verified (size: $file_size bytes)"
  
  # Extract CEF archive
  rm -rf "$CEF_ROOT_DIR"
  mkdir -p "$CEF_ROOT_DIR"
  echo "::notice::Extracting CEF archive..."
  
  if ! tar -xJf "$cef_archive" -C "$CEF_ROOT_DIR"; then
    echo "::error::Tar extraction failed"
    echo "::error::Archive file info: $(file "$cef_archive" 2>/dev/null || echo 'file not found')"
    echo "::error::Archive size: $(stat -c%s "$cef_archive" 2>/dev/null || echo 'unknown') bytes"
    exit 1
  fi
  
  echo "::notice::Successfully extracted CEF archive"
  
  # Handle potential nested directory structure
  if [[ -d "$CEF_ROOT_DIR/cef_binary_6533_linux_aarch64" ]]; then
    echo "::notice::Moving contents from nested directory cef_binary_6533_linux_aarch64"
    mv "$CEF_ROOT_DIR/cef_binary_6533_linux_aarch64"/* "$CEF_ROOT_DIR/" 2>/dev/null || true
    rmdir "$CEF_ROOT_DIR/cef_binary_6533_linux_aarch64" 2>/dev/null || true
  elif [[ -d "$CEF_ROOT_DIR/cef_binary_${CEF_VERSION}" ]]; then
    echo "::notice::Moving contents from nested directory cef_binary_${CEF_VERSION}"
    mv "$CEF_ROOT_DIR/cef_binary_${CEF_VERSION}"/* "$CEF_ROOT_DIR/" 2>/dev/null || true
    rmdir "$CEF_ROOT_DIR/cef_binary_${CEF_VERSION}" 2>/dev/null || true
  fi
  
  # Verify CEF extraction with detailed error reporting
  echo "::notice::Verifying CEF extraction..."
  echo "::notice::CEF directory contents:"
  ls -la "$CEF_ROOT_DIR" || true
  
  if [[ ! -f "$CEF_ROOT_DIR/Release/libcef.so" ]]; then
    echo "::error::CEF extraction failed - libcef.so not found in $CEF_ROOT_DIR/Release/"
    echo "::error::Available files in Release directory:"
    ls -la "$CEF_ROOT_DIR/Release/" 2>/dev/null || echo "::error::Release directory does not exist"
    exit 1
  fi
  
  # Verify pre-compiled wrapper is present
  if [[ ! -f "$CEF_ROOT_DIR/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
    echo "::error::Pre-compiled CEF wrapper not found - libcef_dll_wrapper.a missing"
    echo "::error::Available files in build/libcef_dll_wrapper directory:"
    ls -la "$CEF_ROOT_DIR/build/libcef_dll_wrapper/" 2>/dev/null || echo "::error::build/libcef_dll_wrapper directory does not exist"
    exit 1
  fi
  
  echo "::notice::Pre-compiled CEF setup completed successfully for ARM64"
  echo "::notice::CEF wrapper found at: $CEF_ROOT_DIR/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
  end_group
}

clone_repos() {
  log "Cloning repositories"
  
  # Clone all repos in parallel
  local pids=()
  
  # OBS Studio
  if [[ ! -d "$OBS_SRC_DIR/.git" ]] || ! (cd "$OBS_SRC_DIR" && [[ "$(git describe --tags --exact-match 2>/dev/null || echo unknown)" == "$OBS_VERSION" ]]); then
    (
      rm -rf "$OBS_SRC_DIR"
      git clone --depth=1 --branch="$OBS_VERSION" \
        --recurse-submodules --shallow-submodules \
        https://github.com/obsproject/obs-studio.git "$OBS_SRC_DIR"
    ) &
    pids+=($!)
  fi
  
  # FFmpeg Rockchip
  if [[ ! -d "$FFMPEG_SRC_DIR/.git" ]] || ! (cd "$FFMPEG_SRC_DIR" && [[ "$(git branch --show-current 2>/dev/null || echo unknown)" == "$FFMPEG_BRANCH" ]]); then
    (
      rm -rf "$FFMPEG_SRC_DIR"
      git clone --depth=1 --branch="$FFMPEG_BRANCH" \
        https://github.com/nyanmisaka/ffmpeg-rockchip.git "$FFMPEG_SRC_DIR"
    ) &
    pids+=($!)
  fi
  
  # MPP
  if [[ ! -d "$MPP_SRC_DIR/.git" ]]; then
    (
      git clone -b jellyfin-mpp --depth=1 \
        https://github.com/nyanmisaka/mpp.git "$MPP_SRC_DIR"
    ) &
    pids+=($!)
  fi
  
  # RGA
  if [[ ! -d "$RGA_SRC_DIR/.git" ]]; then
    (
      git clone -b jellyfin-rga --depth=1 \
        https://github.com/nyanmisaka/rk-mirrors.git "$RGA_SRC_DIR"
    ) &
    pids+=($!)
  fi
  
  # Wait for all clones to complete
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  
  end_group
}

build_mpp() {
  # Check if already built
  if [[ -f "$PREFIX_DIR/lib/pkgconfig/rockchip_mpp.pc" ]]; then
    log "MPP already built, skipping"
    export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
    end_group
    return 0
  fi

  log "Building Rockchip MPP"
  
  cd "$MPP_SRC_DIR"
  mkdir -p build
  cd build
  
  cmake \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TEST=OFF \
    ..
  
  make -j"$NUM_JOBS"
  make install
  
  export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
  
  end_group
}

build_rga() {
  # Check if already built
  if [[ -f "$PREFIX_DIR/lib/pkgconfig/librga.pc" ]]; then
    log "RGA already built, skipping"
    export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
    end_group
    return 0
  fi

  log "Building Rockchip RGA"
  
  cd "$RGA_SRC_DIR"
  meson setup build \
    --prefix="$PREFIX_DIR" \
    --libdir=lib \
    --buildtype=release \
    --default-library=shared \
    -Dcpp_args=-fpermissive \
    -Dlibdrm=false \
    -Dlibrga_demo=false
  
  meson configure build
  ninja -C build -j"$NUM_JOBS" install
  
  export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
  
  end_group
}

build_ffmpeg_rockchip() {
  # Check if already built
  if [[ -f "$PREFIX_DIR/bin/ffmpeg" && -f "$PREFIX_DIR/lib/pkgconfig/libavcodec.pc" ]]; then
    log "FFmpeg already built, skipping"
    export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
    export PATH="$PREFIX_DIR/bin:$PATH"
    end_group
    return 0
  fi

  log "Building FFmpeg Rockchip"
  
  cd "$FFMPEG_SRC_DIR"
  
  # Ensure we have the dependencies
  pkg-config --exists rockchip_mpp librga || {
    echo "::error::Missing rockchip_mpp or librga pkg-config"
    exit 1
  }
  
  # Configure with optimized flags for CI
  ./configure \
    --prefix="$PREFIX_DIR" \
    --enable-gpl --enable-version3 --enable-nonfree \
    --enable-libx264 --enable-libx265 --enable-libvpx \
    --enable-libdrm --enable-libv4l2 --enable-openssl \
    --enable-rkmpp --enable-rkrga \
    --extra-cflags="-I$PREFIX_DIR/include -O2 -pipe" \
    --extra-ldflags="-L$PREFIX_DIR/lib -Wl,--as-needed" \
    --enable-shared --disable-static \
    --disable-doc --disable-htmlpages --disable-manpages \
    --disable-podpages --disable-txtpages
  
  make -j"$NUM_JOBS"
  make install
  
  # Normalize version for OBS compatibility
  local ffver_h="$PREFIX_DIR/include/libavutil/ffversion.h"
  if [[ -f "$ffver_h" ]]; then
    sed -i 's/^\([[:space:]]*#define[[:space:]]\+FFMPEG_VERSION[[:space:]]\+\).*/\1"6.1"/' "$ffver_h" || true
  fi
  
  export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="$PREFIX_DIR/lib:${LD_LIBRARY_PATH:-}"
  export PATH="$PREFIX_DIR/bin:$PATH"
  
  end_group
}

build_obs() {
  log "Building OBS Studio with Browser Support"
  
  cd "$OBS_SRC_DIR"
  
  # Install OBS build dependencies
  if [[ -f debian/control ]]; then
    sudo mk-build-deps -ir -t "apt-get -y --no-install-recommends" debian/control
  fi
  
  # Verify CEF is ready (pre-compiled wrapper)
  if [[ ! -f "$CEF_ROOT_DIR/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
    echo "::error::Pre-compiled CEF wrapper not found at expected location"
    exit 1
  fi
  
  # Create optimized preset for CI with CEF
  tee CMakeUserPresets.json > /dev/null << EOF
{
  "version": 8,
  "cmakeMinimumRequired": {"major": 3, "minor": 28, "patch": 0},
  "configurePresets": [
    {
      "name": "ci-build",
      "binaryDir": "\${sourceDir}/build",
      "generator": "Ninja",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "$BUILD_TYPE",
        "CMAKE_C_FLAGS": "-D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE",
        "CMAKE_CXX_FLAGS": "-D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE", 
        "FFMPEG_ROOT": "$PREFIX_DIR",
        "CMAKE_PREFIX_PATH": "$PREFIX_DIR",
        "CEF_ROOT_DIR": "$CEF_ROOT_DIR",
        "UNIX_STRUCTURE": true,
        "ENABLE_BROWSER": true,
        "ENABLE_PIPEWIRE": true,
        "ENABLE_WAYLAND": true,
        "ENABLE_QT6": true,
        "ENABLE_FDK": true,
        "ENABLE_AJA": false,
        "ENABLE_VLC": true,
        "ENABLE_WEBRTC": false,
        "ENABLE_CCACHE": $([[ "$USE_CCACHE" == "1" ]] && echo "true" || echo "false"),
        "CMAKE_UNITY_BUILD": $([[ "$ENABLE_UNITY_BUILD" == "1" ]] && echo "true" || echo "false")
      }
    }
  ]
}
EOF

  cmake --preset ci-build
  cmake --build build -j"$NUM_JOBS"
  
  if [[ "$RUN_TESTS" == "1" ]]; then
    cd build && ctest --output-on-failure -j"$NUM_JOBS"
    cd ..
  fi
  
  # Copy CEF binaries to the build directory for packaging
  echo "::notice::Copying CEF binaries for packaging"
  local obs_build_dir="$OBS_SRC_DIR/build"
  local cef_release_dir="$CEF_ROOT_DIR/Release"
  local cef_resources_dir="$CEF_ROOT_DIR/Resources"
  
  # Create CEF directory structure in build
  mkdir -p "$obs_build_dir/obs-plugins/64bit"
  mkdir -p "$obs_build_dir/bin/64bit"
  
  # Copy CEF shared libraries
  cp -v "$cef_release_dir/libcef.so" "$obs_build_dir/obs-plugins/64bit/"
  cp -v "$cef_release_dir"/lib*.so "$obs_build_dir/obs-plugins/64bit/" 2>/dev/null || true
  
  # Copy CEF resources
  if [[ -d "$cef_resources_dir" ]]; then
    cp -rv "$cef_resources_dir"/* "$obs_build_dir/bin/64bit/" 2>/dev/null || true
  fi
  
  # Copy CEF executables
  if [[ -f "$cef_release_dir/chrome-sandbox" ]]; then
    cp -v "$cef_release_dir/chrome-sandbox" "$obs_build_dir/bin/64bit/"
    chmod +x "$obs_build_dir/bin/64bit/chrome-sandbox"
  fi
  
  # Generate packages
  cd build && cpack -G DEB
  
  # Show ccache stats
  if command -v ccache >/dev/null 2>&1; then
    echo "::notice::ccache stats: $(ccache --show-stats --verbose | grep -E '(cache hit|cache miss|cache hit rate)')"
  fi
  
  end_group
}

package_artifacts() {
  log "Packaging artifacts"
  
  local out="$WORKSPACE/artifacts"
  mkdir -p "$out"
  
  # Collect .deb files
  find "$WORKSPACE" -name "*.deb" -exec cp -v {} "$out/" \; 2>/dev/null || true
  
  # Create a manifest of what was built
  tee "$out/build_info.txt" > /dev/null << EOF
Build Information:
- Date: $(date)
- OBS Version: $OBS_VERSION
- FFmpeg Branch: $FFMPEG_BRANCH  
- CEF Version: $CEF_VERSION (pre-compiled from OBS Project)
- CEF Architecture: $CEF_ARCH (ARM64 only)
- Build Type: $BUILD_TYPE
- Browser Support: Enabled (pre-compiled wrapper)
- ccache: $USE_CCACHE
- Unity Build: $ENABLE_UNITY_BUILD
- Target Platform: Rockchip ARM64 (RK3588/RK3588s)
EOF
  
  # List generated artifacts for GitHub Actions
  if [[ -n "$(ls -A "$out" 2>/dev/null)" ]]; then
    echo "::notice::Generated artifacts:"
    ls -la "$out"
  else
    echo "::warning::No artifacts generated"
  fi
  
  end_group
}

main() {
  echo "::notice::Starting OBS Rockchip ARM64 build with Browser support ($(date))"
  echo "::notice::Build configuration: $BUILD_TYPE, Jobs: $NUM_JOBS, ccache: $USE_CCACHE"
  echo "::notice::CEF version: $CEF_VERSION (pre-compiled from OBS Project)"
  echo "::notice::Target platform: Rockchip ARM64 (RK3588/RK3588s)"
  
  setup_ccache
  install_deps
  clone_repos
  download_and_setup_cef
  build_mpp
  build_rga  
  build_ffmpeg_rockchip
  build_obs
  package_artifacts
  
  echo "::notice::Build completed successfully ($(date))"
}

main "$@"
