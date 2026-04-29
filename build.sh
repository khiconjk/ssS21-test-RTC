#!/bin/bash
set -e

abort()
{
    cd - 2>/dev/null || true
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit 1
}

unset_flags()
{
    cat << EOF
Usage: $(basename "$0") [options]
Options:
    -m, --model [value]    Specify the model code of the phone
    -k, --ksu [y/N]        Include KernelSU
    -s, --susfs [y/N]      Include SuSFS
    -r, --recovery [y/N]   Compile kernel for Android Recovery
EOF
}

MODEL=""
KSU_OPTION=""
SUSFS_OPTION=""
RECOVERY_OPTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m)
            MODEL="$2"
            shift 2
            ;;
        --ksu|-k)
            KSU_OPTION="$2"
            shift 2
            ;;
        --susfs|-s)
            SUSFS_OPTION="$2"
            shift 2
            ;;
        --recovery|-r)
            RECOVERY_OPTION="$2"
            shift 2
            ;;
        *)
            unset_flags
            exit 1
            ;;
    esac
done

[ -z "$MODEL" ] && MODEL="o1s"

fetch_ksu()
{
    rm -rf "$PWD/KernelSU-Next"

    echo "Fetching KernelSU Next"
    if [ -d ".git" ]; then
        git submodule update --init KernelSU-Next || {
            echo "Submodule failed, cloning KernelSU-Next manually..."
            git clone --depth=1 https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next || abort
        }
    else
        git clone --depth=1 https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next || abort
    fi
}

enable_susfs()
{
    echo "Applying SuSFS patch to KernelSU Next..."
    patch -d "$PWD/KernelSU-Next" -p1 < "$PWD/patches/enable-susfs.patch" || abort
}

echo "Preparing the build environment..."
cd "$(dirname "$0")"

CORES=$(nproc)

echo "Cleaning old output..."
rm -rf out
rm -rf "build/out/$MODEL"
find . -name "*.a" -delete || true

# ================= TOOLCHAIN =================
CLANG_DIR=$PWD/toolchain/clang-r596125
export PATH=$CLANG_DIR/bin:$PATH

if [ ! -x "$CLANG_DIR/bin/clang" ]; then
    echo "Downloading clang..."
    rm -rf toolchain/clang-r596125
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

# ================= BOARD =================
case "$MODEL" in
    r9s)
        BOARD=SRPUG16A010KU
        ;;
    o1s)
        BOARD=SRPTH19C011KU
        ;;
    t2s)
        BOARD=SRPTG24B014KU
        ;;
    p3s)
        BOARD=SRPTH19D013KU
        ;;
    *)
        unset_flags
        exit 1
        ;;
esac

# ================= FLAGS =================
if [[ "$RECOVERY_OPTION" == "y" ]]; then
    RECOVERY=recovery.config
    KSU_OPTION=n
    SUSFS_OPTION=n
fi

if [ -z "$KSU_OPTION" ]; then
    KSU_OPTION=n
fi

if [ -z "$SUSFS_OPTION" ]; then
    SUSFS_OPTION=n
fi

if [[ "$KSU_OPTION" == "y" ]]; then
    KSU=ksu.config
else
    KSU=""
fi

if [[ "$SUSFS_OPTION" == "y" ]]; then
    SUSFS=susfs.config
else
    SUSFS=""
fi

# ================= STOCK BUILD INFO =================
touch .scmversion
export LOCALVERSION="-22936777-abG991BXXS3BUL1"
export KBUILD_BUILD_USER="dpi"
export KBUILD_BUILD_HOST="21DJ6C20"
export KBUILD_BUILD_TIMESTAMP="Tue Nov 30 18:48:28 KST 2021"
export KBUILD_BUILD_VERSION="2"

# ================= GHOST UPTIME HEADER =================
mkdir -p include/linux

cat > include/linux/ghost_uptime.h <<'EOF'
#ifndef _LINUX_GHOST_UPTIME_H
#define _LINUX_GHOST_UPTIME_H

#include <linux/types.h>

extern u64 arch_sys_boot_offset;

#endif
EOF

# Không tạo kernel/ghost_uptime.c ở đây nữa.
# arch_sys_boot_offset đã được define trong kernel/time/timekeeping.c

# ================= PATCH STAT =================
echo "Patching fs/stat.c..."

if ! grep -q "GHOST UPTIME FOR STAT" fs/stat.c; then
    if ! grep -q "linux/ghost_uptime.h" fs/stat.c; then
        sed -i '/#include <linux\/uaccess.h>/a #include <linux/ghost_uptime.h>' fs/stat.c
    fi

    if ! grep -q "linux/math64.h" fs/stat.c; then
        sed -i '/#include <linux\/ghost_uptime.h>/a #include <linux/math64.h>' fs/stat.c
    fi

    sed -i '/stat->blocks = inode->i_blocks;/a \
\
\t/* --- GHOST UPTIME FOR STAT --- */\
\tif (inode->i_sb && arch_sys_boot_offset > 0) {\
\t\tunsigned long magic = inode->i_sb->s_magic;\
\
\t\tif (magic == 0x9fa0 || magic == 0x62656572 || magic == 0x1373 ||\
\t\t    magic == 0x01021994 || magic == 0x73636673 || magic == 0x64626720 ||\
\t\t    magic == 0x27e0eb || magic == 0x6e736673) {\
\t\t\tu64 offset = div_u64(arch_sys_boot_offset, 1000000000);\
\
\t\t\tstat->atime.tv_sec -= offset;\
\t\t\tstat->mtime.tv_sec -= offset;\
\t\t\tstat->ctime.tv_sec -= offset;\
\t\t}\
\t}\
\t/* -------------------------------- */' fs/stat.c
else
    echo "fs/stat.c already patched"
fi

# ================= PATCH TIMEKEEPING EXPORT =================
echo "Checking arch_sys_boot_offset export..."

if grep -q "u64 arch_sys_boot_offset = 0;" kernel/time/timekeeping.c; then
    if ! grep -q "EXPORT_SYMBOL_GPL(arch_sys_boot_offset);" kernel/time/timekeeping.c; then
        sed -i '/u64 arch_sys_boot_offset = 0;/a EXPORT_SYMBOL_GPL(arch_sys_boot_offset);' kernel/time/timekeeping.c
    fi
else
    echo "ERROR: arch_sys_boot_offset not found in kernel/time/timekeeping.c"
    exit 1
fi

# ================= FIX RTC API =================
if grep -q "rtc_tm_to_time64(&tm, &tv64.tv_sec)" drivers/rtc/hctosys.c; then
    sed -i 's/rtc_tm_to_time64(&tm, &tv64.tv_sec);/tv64.tv_sec = rtc_tm_to_time64(\&tm);/g' drivers/rtc/hctosys.c
fi

# ================= PREPARE KSU/SUSFS =================
KCONFIG_FILE="drivers/Kconfig"
KSU_LINE='source "drivers/kernelsu/Kconfig"'
MAKEFILE="drivers/Makefile"
MAKEFILE_LINE='obj-$(CONFIG_KSU) += kernelsu/'

if [[ "$KSU_OPTION" == "y" ]]; then
    fetch_ksu

    if [[ "$SUSFS_OPTION" == "y" ]]; then
        enable_susfs
    fi

    if ! grep -Fxq "$KSU_LINE" "$KCONFIG_FILE"; then
        sed -i "\|endmenu|i $KSU_LINE" "$KCONFIG_FILE"
    fi

    if ! grep -Fxq "$MAKEFILE_LINE" "$MAKEFILE"; then
        echo "$MAKEFILE_LINE" >> "$MAKEFILE"
    fi
else
    sed -i "\|$KSU_LINE|d" "$KCONFIG_FILE" || true
    sed -i "\|$MAKEFILE_LINE|d" "$MAKEFILE" || true
fi

# ================= OUTPUT DIRS =================
mkdir -p "build/out/$MODEL/zip/files"
mkdir -p "build/out/$MODEL/zip/META-INF/com/google/android"

build_kernel()
{
    echo "-----------------------------------------------"
    echo "Defconfig:"
    echo "MODEL: $MODEL"
    echo "KSU: ${KSU:-N}"
    echo "SUSFS: ${SUSFS:-N}"
    echo "Recovery: ${RECOVERY:-N}"
    echo "-----------------------------------------------"

    make ${MAKE_ARGS} -j$CORES exynos2100_defconfig "$MODEL.config" $RECOVERY $KSU $SUSFS || abort

    echo "Building kernel..."
    make ${MAKE_ARGS} -j$CORES || abort
}

build_boot()
{
    cp -a out/arch/arm64/boot/Image "build/out/$MODEL/Image"

    if [ -z "$RECOVERY" ]; then
        echo "-----------------------------------------------"
        echo "Building boot.img RAMDisk..."

        rm -rf "build/out/$MODEL/boot_ramdisk00"
        cp -a build/ramdisk/boot/boot_ramdisk00 "build/out/$MODEL/boot_ramdisk00"

        pushd "build/out/$MODEL/boot_ramdisk00" > /dev/null
        find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | lz4 -l > ../boot_ramdisk || abort
        popd > /dev/null

        echo "Building boot.img..."

        python3 toolchain/mkbootimg/mkbootimg.py \
            --header_version 3 \
            --cmdline "androidboot.selinux=permissive loop.max_part=7" \
            --ramdisk "build/out/$MODEL/boot_ramdisk" \
            --os_version 16.0.0 \
            --os_patch_level 2025-11 \
            --kernel "build/out/$MODEL/Image" \
            --output "build/out/$MODEL/boot.img" || abort
    fi
}

build_dtb()
{
    echo "-----------------------------------------------"
    echo "Building DTB image..."

    ./toolchain/mkdtimg cfg_create "build/out/$MODEL/dtb.img" \
        dt.configs/exynos2100.cfg \
        -d out/arch/arm64/boot/dts/exynos || abort

    echo "Building DTBO image..."

    ./toolchain/mkdtimg cfg_create "build/out/$MODEL/dtbo.img" \
        "dt.configs/$MODEL.cfg" \
        -d "out/arch/arm64/boot/dts/samsung/$MODEL" || abort
}

build_modules()
{
    MODULES_FOLDER=modules
    rm -rf "out/$MODULES_FOLDER"

    echo "-----------------------------------------------"
    echo "Building modules..."

    make ${MAKE_ARGS} INSTALL_MOD_PATH=$MODULES_FOLDER INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" modules_install || abort

    FILENAMES="
    sec_debug_sched_info.ko
    "

    for FILENAME in $FILENAMES; do
        FILE=$(find "out/$MODULES_FOLDER" -type f -name "$FILENAME")
        echo "$FILE" | xargs rm -f || true
    done

    KERNEL_DIR_PATH=$(find "out/$MODULES_FOLDER/lib/modules" -maxdepth 1 -type d -name "5.4*" | head -n 1) || abort
    KERNEL_VERSION=$(basename "$KERNEL_DIR_PATH") || abort

    depmod -a -b "out/$MODULES_FOLDER" "$KERNEL_VERSION" || abort

    sed -i 's/.*\///g' "$KERNEL_DIR_PATH/modules.order"

    for FILENAME in $FILENAMES; do
        sed -i "/$FILENAME/d" "$KERNEL_DIR_PATH/modules.order"
    done

    : > "$KERNEL_DIR_PATH/modules.load"

    INITIAL_ORDER="
    dss.ko
    exynos-chipid_v2.ko
    exynos-reboot.ko
    exynos2100-itmon.ko
    exynos-pmu-if.ko
    s3c2410_wdt.ko
    exynos-ecc-handler.ko
    debug-snapshot-qd.ko
    eat.ko
    exynos-adv-tracer-s2d.ko
    ehld.ko
    exynos-debug-test.ko
    hardlockup-debug.ko
    exynos_acpm.ko
    exynos_pm_qos.ko
    exynos-s2mpu.ko
    exynos-pd_el3.ko
    ect_parser.ko
    cmupmucal.ko
    clk_exynos.ko
    clk-exynos-audss.ko
    exynos_mct.ko
    pinctrl-samsung-core.ko
    exynos-cpupm.ko
    i2c-exynos5.ko
    acpm-mfd-bus.ko
    s2mps24_mfd.ko
    s2mps23_mfd.ko
    pmic_class.ko
    s2mps23-regulator.ko
    s2mps24-regulator.ko
    phy-exynos-usbdrd-super.ko
    sec_debug_mode.ko
    fingerprint.ko
    "

    for LINE in $INITIAL_ORDER; do
        echo "$LINE" >> "$KERNEL_DIR_PATH/modules.load"
        sed -i "/$LINE/d" "$KERNEL_DIR_PATH/modules.order"
    done

    while IFS= read -r line; do
        echo "$line" >> "$KERNEL_DIR_PATH/modules.load"
    done < "$KERNEL_DIR_PATH/modules.order"

    sed -i 's/\(kernel\/[^: ]*\/\)\([^: ]*\.ko\)/\/lib\/modules\/\2/g' "$KERNEL_DIR_PATH/modules.dep"

    mkdir -p "build/out/$MODEL/modules/lib/modules"
    find "$KERNEL_DIR_PATH" -name '*.ko' -exec cp '{}' "build/out/$MODEL/modules/lib/modules" ';'
    cp "$KERNEL_DIR_PATH"/modules.{alias,dep,softdep,load} "build/out/$MODEL/modules/lib/modules"
}

build_vendor_boot()
{
    echo "-----------------------------------------------"
    echo "Building vendor_boot RAMDisks..."

    rm -rf "build/out/$MODEL/vendor_ramdisk00"
    cp -a build/ramdisk/vendor_boot/ramdisk00 "build/out/$MODEL/vendor_ramdisk00"

    cp -a "build/out/$MODEL/modules/lib/"* "build/out/$MODEL/vendor_ramdisk00/lib"
    cp -a "build/ramdisk/vendor_boot/vendor_firmware/$MODEL/"* "build/out/$MODEL/vendor_ramdisk00"

    pushd "build/out/$MODEL/vendor_ramdisk00" > /dev/null
    find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip -c > ../vendor_ramdisk || abort
    popd > /dev/null

    echo "Building vendor_boot image..."

    python3 toolchain/mkbootimg/mkbootimg.py \
        --header_version 3 \
        --pagesize 0x00001000 \
        --base 0x00000000 \
        --kernel_offset 0x80008000 \
        --ramdisk_offset 0x84000000 \
        --tags_offset 0x80000000 \
        --dtb_offset 0x0000000081F00000 \
        --vendor_cmdline "androidboot.selinux=permissive loop.max_part=7" \
        --board "$BOARD" \
        --dtb "build/out/$MODEL/dtb.img" \
        --vendor_ramdisk "build/out/$MODEL/vendor_ramdisk" \
        --vendor_boot "build/out/$MODEL/vendor_boot.img" || abort
}

build_zip()
{
    echo "-----------------------------------------------"
    echo "Building AK3 zip..."

    AK3_DIR="$PWD/AnyKernel3"
    AK3_REPO="https://github.com/xfwdrev/AnyKernel3.git"
    AK3_BRANCH="t2s"

    if [ ! -d "$AK3_DIR/.git" ]; then
        git clone -b "$AK3_BRANCH" "$AK3_REPO" "$AK3_DIR" || abort
    else
        git -C "$AK3_DIR" fetch origin "$AK3_BRANCH" || abort
        git -C "$AK3_DIR" checkout "$AK3_BRANCH" || abort
        git -C "$AK3_DIR" reset --hard "origin/$AK3_BRANCH" || abort
        git -C "$AK3_DIR" clean -fd || abort
    fi

    rm -f "$AK3_DIR/boot.img" "$AK3_DIR/vendor_boot.img" "$AK3_DIR/dtbo.img"

    [ -f "build/out/$MODEL/boot.img" ] && cp "build/out/$MODEL/boot.img" "$AK3_DIR/"
    [ -f "build/out/$MODEL/dtbo.img" ] && cp "build/out/$MODEL/dtbo.img" "$AK3_DIR/"
    [ -f "build/out/$MODEL/vendor_boot.img" ] && cp "build/out/$MODEL/vendor_boot.img" "$AK3_DIR/"

    [[ "$MODEL" != "t2s" ]] && sed -i "s/^device\.name1=.*/device.name1=$MODEL/" "$AK3_DIR/anykernel.sh"

    pushd "$AK3_DIR" > /dev/null

    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' ../arch/arm64/configs/exynos2100_defconfig | cut -d '"' -f 2)
    version=${version:1}
    DATE=$(date +"%d-%m-%Y_%H-%M-%S")

    if [[ "$KSU_OPTION" == "y" && "$SUSFS_OPTION" == "y" ]]; then
        NAME="${version}_${MODEL}_KSUN_SUSFS_${DATE}.zip"
    elif [[ "$KSU_OPTION" == "y" ]]; then
        NAME="${version}_${MODEL}_KSUN_${DATE}.zip"
    else
        NAME="${version}_${MODEL}_VANILLA_${DATE}.zip"
    fi

    zip -r9 "../build/out/$MODEL/$NAME" * -x ".git*" "README.md" "*placeholder" || abort
    popd > /dev/null
}

build_kernel
build_boot
build_dtb
build_modules

if [ -z "$RECOVERY" ]; then
    build_vendor_boot
    build_zip
fi

echo "-----------------------------------------------"
echo "Build finished successfully!"
