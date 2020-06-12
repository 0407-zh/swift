#/bin/bash

set -ex
SOURCE_PATH="$(cd "$(dirname $0)/../../.." && pwd)"
UTILS_PATH="$(cd "$(dirname $0)" && pwd)"

WASI_SDK_PATH=$SOURCE_PATH/wasi-sdk

case $(uname -s) in
  Darwin)
    OS_SUFFIX=osx
    PRESET_NAME=webassembly-macos-installable
  ;;
  Linux)
    OS_SUFFIX=linux
    PRESET_NAME=webassembly-linux-installable
  ;;
  *)
    echo "Unrecognised platform $(uname -s)"
    exit 1
  ;;
esac

YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
TOOLCHAIN_VERSION="${YEAR}${MONTH}${DAY}"
TOOLCHAIN_NAME="swift-wasm-DEVELOPMENT-SNAPSHOT-${YEAR}-${MONTH}-${DAY}-a"
ARCHIVE="${TOOLCHAIN_NAME}-${OS_SUFFIX}.tar.gz"
INSTALLABLE_PACKAGE=$SOURCE_PATH/$ARCHIVE

PACKAGE_ARTIFACT="$SOURCE_PATH/swift-wasm-DEVELOPMENT-SNAPSHOT-${OS_SUFFIX}.tar.gz"

BUNDLE_IDENTIFIER="swiftwasm.${YEAR}${MONTH}${DAY}"
DISPLAY_NAME_SHORT="Swift for WebAssembly Development Snapshot"
DISPLAY_NAME="${DISPLAY_NAME_SHORT} ${YEAR}-${MONTH}-${DAY}"

# Make sure Clang headers install dir exists to avoid broken symlinks
mkdir -p $SOURCE_PATH/install/$TOOLCHAIN_NAME/usr/lib/clang/10.0.0

$SOURCE_PATH/swift/utils/build-script --preset=$PRESET_NAME \
  SOURCE_PATH="$SOURCE_PATH" \
  INSTALLABLE_PACKAGE="$INSTALLABLE_PACKAGE" \
  BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER}" \
  DISPLAY_NAME="${DISPLAY_NAME}" \
  DISPLAY_NAME_SHORT="${DISPLAY_NAME_SHORT}" \
  TOOLCHAIN_NAME="${TOOLCHAIN_NAME}" \
  TOOLCHAIN_VERSION="${TOOLCHAIN_VERSION}" \
  C_CXX_LAUNCHER="$(which sccache)"


NIGHTLY_TOOLCHAIN=$SOURCE_PATH/swift-nightly-toolchain
if [ ! -e $NIGHTLY_TOOLCHAIN ]; then
  $UTILS_PATH/install-nightly-toolchain.sh
fi

TMP_DIR=$(mktemp -d)
cd $TMP_DIR
tar xfz $INSTALLABLE_PACKAGE $TOOLCHAIN_NAME
cd $TMP_DIR/$TOOLCHAIN_NAME

# Merge wasi-sdk and toolchain
cp -r $WASI_SDK_PATH/lib/clang usr/lib
cp -a $WASI_SDK_PATH/bin/{*ld,llvm-ar} usr/bin
cp -r $WASI_SDK_PATH/share/wasi-sysroot usr/share

# Build SwiftPM and install it into toolchain
$UTILS_PATH/build-swiftpm.sh $TMP_DIR/$TOOLCHAIN_NAME

# Replace absolute sysroot path with relative path
sed -i -e "s@\".*/include@\"../../../../share/wasi-sysroot/include@g" $TMP_DIR/$TOOLCHAIN_NAME/usr/lib/swift/wasi/wasm32/glibc.modulemap

# Copy nightly-toolchain's host environment stdlib into toolchain

# Avoid to copy usr/lib/swift/clang because our toolchain's one is a directory
# but nightly's one is symbolic link, so fail to merge them.
rsync -a $NIGHTLY_TOOLCHAIN/usr/lib/ $TMP_DIR/$TOOLCHAIN_NAME/usr/lib/ --exclude 'swift/clang'

$UTILS_PATH/build-foundation.sh $TMP_DIR/$TOOLCHAIN_NAME
$UTILS_PATH/build-xctest.sh $TMP_DIR/$TOOLCHAIN_NAME

cd $TMP_DIR
tar cfz $PACKAGE_ARTIFACT $TOOLCHAIN_NAME
