#!/bin/bash
set -e

abort() {
    echo "BUILD FAILED"
    exit 1
}

cd "$(dirname "$0")"

CORES=$(nproc)

echo "Cleaning..."
rm -rf out build
find . -name "*.a" -delete

# ================= TOOLCHAIN =================
CLANG_DIR=$PWD/toolchain/clang-r596125
export PATH=$CLANG_DIR/bin:$PATH

if [ ! -x "$CLANG_DIR/bin/clang" ]; then
    echo "Downloading clang..."
    mkdir -p toolchain/clang-r596125

    wget -O toolchain/clang.tar.gz \
    "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/mirror-goog-main-llvm-toolchain-source/clang-r596125.tar.gz"

    tar -xf toolchain/clang.tar.gz -C toolchain/clang-r596125
fi

MAKE_ARGS="
LLVM=1
LLVM_IAS=1
ARCH=arm64
O=out
"

MODEL=o1s

# ================= GHOST UPTIME =================
mkdir -p include/linux
mkdir -p kernel

cat > include/linux/ghost_uptime.h <<'EOF'
#ifndef _LINUX_GHOST_UPTIME_H
#define _LINUX_GHOST_UPTIME_H
#include <linux/types.h>
#endif
EOF

grep -q ghost_uptime.o kernel/Makefile || echo "obj-y += ghost_uptime.o" >> kernel/Makefile

# ================= PATCH STAT =================
if ! grep -q "GHOST UPTIME FOR STAT" fs/stat.c; then

sed -i '/#include <linux\/uaccess.h>/a \
#include <linux/ghost_uptime.h>\n#include <linux/math64.h>' fs/stat.c

sed -i '/stat->blocks = inode->i_blocks;/a \
\
\t/* --- GHOST UPTIME FOR STAT --- */\
\tif (inode->i_sb && arch_sys_boot_offset > 0) {\
\t\tunsigned long magic = inode->i_sb->s_magic;\
\t\tif (magic == 0x9fa0 || magic == 0x62656572 || magic == 0x1373 ||\
\t\t    magic == 0x01021994 || magic == 0x73636673 || magic == 0x64626720 ||\
\t\t    magic == 0x27e0eb || magic == 0x6e736673) {\
\t\t\tu64 offset = div_u64(arch_sys_boot_offset, 1000000000);\
\t\t\tstat->atime.tv_sec -= offset;\
\t\t\tstat->mtime.tv_sec -= offset;\
\t\t\tstat->ctime.tv_sec -= offset;\
\t\t}\
\t}\
\t/* -------------------------------- */' fs/stat.c

fi

# ================= BUILD =================
echo "Building kernel..."

make ${MAKE_ARGS} exynos2100_defconfig o1s.config || abort
make ${MAKE_ARGS} -j$CORES || abort

# ================= OUTPUT =================
mkdir -p build/out/o1s
cp out/arch/arm64/boot/Image build/out/o1s/

echo "BUILD SUCCESS"
