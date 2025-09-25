# OBS Rockchip (Work in Progress)

A specialized build of OBS Studio optimized for Rockchip ARM64 platforms (RK3588/RK3588s) with hardware-accelerated video encoding and decoding using Rockchip's MPP (Media Process Platform) and RGA (2D Raster Graphic Acceleration) libraries.

### Downloads
Pre-built .deb packages are available at [Releases](https://github.com/MecoMediaOrg/obs-rockchip/releases)

## Overview

This project provides a complete build pipeline that creates OBS Studio packages with custom FFmpeg-Rockchip integration, enabling hardware-accelerated video processing on Rockchip devices. It's particularly optimized for single-board computers and embedded systems based on the RK3588/RK3588s SoCs.

## Features

### Hardware Acceleration
- **MPP Decoders**: Up to 8K 10-bit H.264, HEVC, VP9, and AV1 decoding
- **MPP Encoders**: Up to 8K H.264 and HEVC encoding with async/frame-parallel support
- **RGA Filters**: Hardware-accelerated image scaling, format conversion, cropping, and blending
- **Zero-copy DMA**: Efficient memory transfers between processing stages
- **AFBC Support**: ARM Frame Buffer Compression for optimized memory usage

### OBS Studio Integration
- Full OBS Studio functionality with hardware acceleration
- Debian package generation for easy installation
- Optimized build with LTO (Link Time Optimization) and ccache support
- Support for all standard OBS sources, filters, and transitions

## Quick Start

### Prerequisites
- Ubuntu/Debian-based system (tested on Ubuntu 24.04)
- ARM64 architecture (RK3588/RK3588s recommended)
- At least 8GB RAM and 20GB free disk space
- sudo privileges for package installation

### Automated Build
```bash
# Clone the repository with submodules
git clone --recursive https://github.com/MecoMediaOrg/obs-rockchip.git
cd obs-rockchip

# Run the automated build script
chmod +x scripts/build-obs-rockchip.sh
./scripts/build-obs-rockchip.sh
```

The build process will:
1. Install all required dependencies
2. Build Rockchip MPP and RGA libraries
3. Compile ffmpeg-rockchip with hardware acceleration
4. Build OBS Studio linked against the custom FFmpeg
5. Generate Debian packages in the `artifacts/` directory

### Manual Installation
After building, install the generated packages:
```bash
sudo dpkg -i artifacts/*.deb
sudo apt-get install -f  # Fix any dependency issues
```

## Build Configuration

The build script supports several environment variables for customization:

```bash
# Build optimization
export NUM_JOBS=8                    # Number of parallel build jobs
export BUILD_TYPE=Release            # Build type (Release/Debug)
export ENABLE_LTO=1                  # Enable Link Time Optimization
export USE_CCACHE=1                  # Enable compiler cache

# Source versions
export OBS_VERSION=32.0.0           # OBS Studio version
export FFMPEG_BRANCH=6.1            # FFmpeg branch

# Paths
export WORKSPACE=/path/to/workspace  # Build workspace
export PREFIX_DIR=/custom/prefix     # Installation prefix
```

## Architecture

This project consists of several components:

- **obs-studio/**: OBS Studio source code (submodule)
- **ffmpeg-rockchip/**: Custom FFmpeg with Rockchip hardware acceleration (submodule)
- **scripts/build-obs-rockchip.sh**: Automated build script
- **.github/workflows/**: GitHub Actions CI/CD configuration

## Hardware Support

### Supported Platforms
- **Primary**: RK3588/RK3588s SoCs
- **Architecture**: ARM64 (aarch64)
- **OS**: Ubuntu/Debian-based Linux distributions

### Hardware Features
- Hardware H.264/HEVC encoding and decoding
- Hardware VP9/AV1 decoding
- Hardware image scaling and format conversion
- Zero-copy memory operations
- Async encoding for improved performance

## Troubleshooting

### Common Issues

**Build fails with missing dependencies:**
```bash
# Update package lists and install missing packages
sudo apt-get update
sudo apt-get install -y build-essential cmake ninja-build
```

**OBS crashes or poor performance:**
- Check system memory usage (hardware acceleration requires sufficient RAM)
- Verify GPU drivers are up to date
- Monitor CPU usage to ensure hardware acceleration is active

### Debug Mode
Enable debug builds for troubleshooting:
```bash
export BUILD_TYPE=Debug
export RUN_TESTS=1
./scripts/build-obs-rockchip.sh
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test the build process
5. Submit a pull request

## Resources

- [FFmpeg Rockchip Wiki](https://github.com/nyanmisaka/ffmpeg-rockchip/wiki)
- [OBS Studio Documentation](https://github.com/obsproject/obs-studio/wiki)

## Support

For issues and questions:
- Create an issue in this repository
- Check the troubleshooting section above
- Review the FFmpeg Rockchip wiki for hardware-specific guidance

---

**Note**: This project is optimized for Rockchip ARM64 platforms. For other architectures, use the standard OBS Studio build process.
