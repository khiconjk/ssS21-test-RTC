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
    -r, --recovery [y/N]   Compile kernel for an Android Recovery
EOF
}

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

fetch_ksu() {
    rm -rf "$PWD/KernelSU-Next"

    echo "Fetching latest KernelSU Next"
    git submodule update --init KernelSU-Next || {
        echo "Failed to initialize KSU Next submodule!"
        exit 1
    }
}

enable_susfs() {
    echo "Applying SuSFS patch to KernelSU Next..."
    patch -d "$PWD/KernelSU-Next" -p1 < "$PWD/patches/enable-susfs.patch" || {
        echo "Failed to apply SuSFS patch!"
        exit 1
    }
}

echo "Preparing the build environment..."

pushd "$(dirname "$0")" > /dev/null
CORES=$(nproc)

# Clean old dirty build output
echo "Cleaning old out directory..."
rm -rf out

# Define toolchain variables
CLANG_DIR=$PWD/toolchain/clang-r596125
export PATH=$CLANG_DIR/bin:$PATH

# --- FAKE STOCK SAMSUNG KERNEL & BYPASS UPTIME ---
touch .scmversion
export LOCALVERSION="-22936777-abG991BXXS3BUL1"
export KBUILD_BUILD_USER="dpi"
export KBUILD_BUILD_HOST="21DJ6C20"
export KBUILD_BUILD_TIMESTAMP="Tue Nov 30 18:48:28 KST 2021"
export KBUILD_BUILD_VERSION="2"
# -------------------------------------------------

# Check toolchain
if [ ! -d "$CLANG_DIR" ] || [ -z "$(ls -A "$CLANG_DIR/bin" 2>/dev/null)" ]; then
    echo "-----------------------------------------------"
    echo "Clang not found! Downloading..."
    echo "-----------------------------------------------"

    mkdir -p toolchain
    cd toolchain

    wget -O clang.tar.gz "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/mirror-goog-main-llvm-toolchain-source/clang-r596125.tar.gz"
    rm -rf clang-r596125
    mkdir -p clang-r596125
    tar -xf clang.tar.gz -C clang-r596125

    cd ..
else
    echo "-----------------------------------------------"
    echo "Using existing clang toolchain"
    echo "-----------------------------------------------"
fi

MAKE_ARGS="
LLVM=1 \
LLVM_IAS=1 \
ARCH=arm64 \
O=out
"

case $MODEL in
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

if [[ "$RECOVERY_OPTION" == "y" ]]; then
    RECOVERY=recovery.config
    KSU_OPTION=n
    SUSFS_OPTION=n
fi

if [ -z "$KSU_OPTION" ]; then
    read -p "Include KernelSU (y/N): " KSU_OPTION
fi

if [[ "$KSU_OPTION" == "y" ]]; then
    KSU=ksu.config
fi

if [[ "$SUSFS_OPTION" == "y" ]]; then
    SUSFS=susfs.config
fi

# ==================== GHOST UPTIME CORE ====================
echo "=== Preparing Ghost Uptime Core ==="

cat > include/linux/ghost_uptime.h << 'EOF'
#ifndef _LINUX_GHOST_UPTIME_H
#define _LINUX_GHOST_UPTIME_H

#include <linux/types.h>

extern u64 arch_sys_boot_offset;

#endif
EOF

cat > kernel/ghost_uptime.c << 'EOF'
#include <linux/types.h>
#include <linux/random.h>
#include <linux/init.h>
#include <linux/ghost_uptime.h>

u64 arch_sys_boot_offset = 0;

void ghost_uptime_init(void)
{
	u32 random_days;

	get_random_bytes(&random_days, sizeof(random_days));
	random_days = 15 + (random_days % 6);

	arch_sys_boot_offset =
		(u64)random_days * 86400ULL * 1000000000ULL;
}

static int __init ghost_uptime_module_init(void)
{
	ghost_uptime_init();
	return 0;
}
early_initcall(ghost_uptime_module_init);
EOF

if ! grep -Fxq "obj-y += ghost_uptime.o" kernel/Makefile; then
    echo "obj-y += ghost_uptime.o" >> kernel/Makefile
fi
# ===========================================================

# ==================== FAKE STAT TIMESTAMPS ====================
echo "=== Applying Fake Stat Timestamps for System Files ==="

mkdir -p patches/uptime

cat > patches/uptime/0002-fake-stat-timestamps.patch << 'EOF'
--- a/fs/stat.c
+++ b/fs/stat.c
@@ -17,8 +17,10 @@
 #include <linux/version.h>
 #endif
 
 #include <linux/uaccess.h>
+#include <linux/ghost_uptime.h>
+#include <linux/math64.h>
 #include <asm/unistd.h>
 
 /**
@@ -50,6 +52,23 @@ void generic_fillattr(struct inode *inode, struct kstat *stat)
 	stat->ctime = inode->i_ctime;
 	stat->blksize = i_blocksize(inode);
 	stat->blocks = inode->i_blocks;
+
+	/* --- GHOST UPTIME FOR STAT (MOMO BYPASS) --- */
+	if (inode->i_sb && arch_sys_boot_offset > 0) {
+		unsigned long magic = inode->i_sb->s_magic;
+
+		if (magic == 0x9fa0 || magic == 0x62656572 || magic == 0x1373 ||
+		    magic == 0x01021994 || magic == 0x73636673 || magic == 0x64626720 ||
+		    magic == 0x27e0eb || magic == 0x6e736673) {
+
+			u64 offset_secs = div_u64(arch_sys_boot_offset, 1000000000);
+
+			stat->atime.tv_sec -= offset_secs;
+			stat->mtime.tv_sec -= offset_secs;
+			stat->ctime.tv_sec -= offset_secs;
+		}
+	}
+	/* ------------------------------------------- */
 #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
 	susfs_generic_fillattr_spoofer(inode, stat);
 #endif
EOF

if grep -q "GHOST UPTIME FOR STAT" fs/stat.c; then
    echo "→ Patch stat.c already applied"
elif patch -p1 --forward --ignore-whitespace --no-backup-if-mismatch < patches/uptime/0002-fake-stat-timestamps.patch; then
    echo "→ Patch stat.c applied"
else
    echo "→ Patch stat.c FAILED"
    exit 1
fi
# ===============================================================

rm -rf build/out/$MODEL
mkdir -p build/out/$MODEL/zip/files
mkdir -p build/out/$MODEL/zip/META-INF/com/google/android

build_kernel() {
    echo "-----------------------------------------------"
    echo "Defconfig: $KERNEL_DEFCONFIG"

    if [[ "$RECOVERY_OPTION" == "y" ]]; then
        RECOVERY=recovery.config
        KSU_OPTION=n
        SUSFS_OPTION=n
    fi

    if [ -z "$KSU" ]; then
        echo "KSU: N"
    else
        echo "KSU: $KSU"
    fi

    if [ -z "$SUSFS" ]; then
        echo "SUSFS: N"
    else
        echo "SUSFS: $SUSFS"
    fi

    if [ -z "$RECOVERY" ]; then
        echo "Recovery: N"
    else
        echo "Recovery: Y"
    fi

    echo "-----------------------------------------------"
    echo "Generating configuration file..."
    echo "-----------------------------------------------"

    make ${MAKE_ARGS} exynos2100_defconfig $MODEL.config $RECOVERY $KSU $SUSFS || abort

    echo "Building kernel..."
    echo "-----------------------------------------------"
    make ${MAKE_ARGS} -j$CORES || abort
}

build_boot() {
    cp -a out/arch/arm64/boot/Image build/out/$MODEL

    if [ -z "$RECOVERY" ]; then
        echo "-----------------------------------------------"
        echo "Building boot.img RAMDisk..."

        mkdir -p build/out/$MODEL/boot_ramdisk00
        cp -a build/ramdisk/boot/boot_ramdisk00 build/out/$MODEL

        pushd build/out/$MODEL/boot_ramdisk00 > /dev/null
        find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | lz4 -l > ../boot_ramdisk || abort
        popd > /dev/null

        echo "-----------------------------------------------"
        echo "Building boot.img..."

        OUTPUT_FILE=build/out/$MODEL/boot.img
        RAMDISK_00=build/out/$MODEL/boot_ramdisk
        KERNEL=build/out/$MODEL/Image
        HEADER_VERSION=3
        OS_VERSION=16.0.0
        OS_PATCH_LEVEL=2025-11
        CMDLINE="androidboot.selinux=permissive loop.max_part=7"

        python3 toolchain/mkbootimg/mkbootimg.py \
            --header_version $HEADER_VERSION \
            --cmdline "$CMDLINE" \
            --ramdisk $RAMDISK_00 \
            --os_version $OS_VERSION \
            --os_patch_level $OS_PATCH_LEVEL \
            --kernel $KERNEL \
            --output $OUTPUT_FILE || abort
    fi
}

build_dtb() {
    echo "-----------------------------------------------"
    echo "Building DTB image..."
    ./toolchain/mkdtimg cfg_create build/out/$MODEL/dtb.img dt.configs/exynos2100.cfg -d out/arch/arm64/boot/dts/exynos || abort

    echo "-----------------------------------------------"
    echo "Building DTBO image..."
    ./toolchain/mkdtimg cfg_create build/out/$MODEL/dtbo.img dt.configs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung/$MODEL || abort
}

build_modules() {
    MODULES_FOLDER=modules
    rm -rf out/$MODULES_FOLDER

    echo "-----------------------------------------------"
    echo "Building modules..."

    make ${MAKE_ARGS} INSTALL_MOD_PATH=$MODULES_FOLDER INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" modules_install || abort

    FILENAMES="
    sec_debug_sched_info.ko
    "

    for FILENAME in $FILENAMES; do
        FILE=$(find out/$MODULES_FOLDER -type f -name "$FILENAME")
        echo "$FILE" | xargs rm -f
    done

    KERNEL_DIR_PATH=$(find "out/$MODULES_FOLDER/lib/modules" -maxdepth 1 -type d -name "5.4*") || abort
    KERNEL_VERSION=$(basename $KERNEL_DIR_PATH) || abort

    depmod -a -b out/$MODULES_FOLDER $KERNEL_VERSION || abort

    sed -i 's/.*\///g' $KERNEL_DIR_PATH/modules.order

    for FILENAME in $FILENAMES; do
        sed -i "/$FILENAME/d" "$KERNEL_DIR_PATH/modules.order"
    done

    touch $KERNEL_DIR_PATH/modules.load

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
        echo $LINE >> $KERNEL_DIR_PATH/modules.load
        sed -i "/$LINE/d" "$KERNEL_DIR_PATH/modules.order"
    done

    while IFS= read -r line; do
        echo "$line" >> "$KERNEL_DIR_PATH/modules.load"
    done < "$KERNEL_DIR_PATH/modules.order"

    sed -i 's/\(kernel\/[^: ]*\/\)\([^: ]*\.ko\)/\/lib\/modules\/\2/g' "$KERNEL_DIR_PATH/modules.dep"

    mkdir -p build/out/$MODEL/modules/lib/modules
    find $KERNEL_DIR_PATH -name '*.ko' -exec cp '{}' build/out/$MODEL/modules/lib/modules ';'
    cp $KERNEL_DIR_PATH/modules.{alias,dep,softdep,load} build/out/$MODEL/modules/lib/modules
}

build_vendor_boot() {
    echo "-----------------------------------------------"
    echo "Building vendor_boot RAMDisks..."

    cp -a build/ramdisk/vendor_boot/ramdisk00 build/out/$MODEL/vendor_ramdisk00
    cp -a build/out/$MODEL/modules/lib/* build/out/$MODEL/vendor_ramdisk00/lib
    cp -a build/ramdisk/vendor_boot/vendor_firmware/$MODEL/* build/out/$MODEL/vendor_ramdisk00

    pushd build/out/$MODEL/vendor_ramdisk00 > /dev/null
    find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip -c > ../vendor_ramdisk || abort
    popd > /dev/null

    echo "-----------------------------------------------"
    echo "Building vendor_boot image..."

    OUTPUT_FILE=build/out/$MODEL/vendor_boot.img
    DTB_PATH=build/out/$MODEL/dtb.img
    RAMDISK_00=build/out/$MODEL/vendor_ramdisk
    HEADER_VERSION=3
    BASE=0x00000000
    PAGESIZE=0x00001000
    KERNEL_OFFSET=0x80008000
    RAMDISK_OFFSET=0x84000000
    TAGS_OFFSET=0x80000000
    DTB_OFFSET=0x0000000081F00000
    CMDLINE="androidboot.selinux=permissive loop.max_part=7"

    python3 toolchain/mkbootimg/mkbootimg.py \
        --header_version $HEADER_VERSION \
        --pagesize $PAGESIZE \
        --base $BASE \
        --kernel_offset $KERNEL_OFFSET \
        --ramdisk_offset $RAMDISK_OFFSET \
        --tags_offset $TAGS_OFFSET \
        --dtb_offset $DTB_OFFSET \
        --vendor_cmdline "$CMDLINE" \
        --board $BOARD \
        --dtb $DTB_PATH \
        --vendor_ramdisk $RAMDISK_00 \
        --vendor_boot $OUTPUT_FILE || abort
}

build_zip() {
    echo "-----------------------------------------------"
    echo "Building AK3 zip..."
    echo "-----------------------------------------------"

    AK3_DIR="$PWD/AnyKernel3"
    AK3_REPO="https://github.com/xfwdrev/AnyKernel3.git"
    AK3_BRANCH="t2s"

    if [ ! -d "$AK3_DIR/.git" ]; then
        echo "AnyKernel3 not found! Cloning ($AK3_BRANCH branch)..."
        git clone -b "$AK3_BRANCH" "$AK3_REPO" "$AK3_DIR" || abort
    else
        echo "AnyKernel3 exists, updating..."
        git -C "$AK3_DIR" fetch origin "$AK3_BRANCH" || abort
        git -C "$AK3_DIR" checkout "$AK3_BRANCH" || abort
        git -C "$AK3_DIR" reset --hard "origin/$AK3_BRANCH" || abort
        git -C "$AK3_DIR" clean -fd || abort
    fi

    rm -f "$AK3_DIR/boot.img"
    rm -f "$AK3_DIR/vendor_boot.img"
    rm -f "$AK3_DIR/dtbo.img"

    [ -f build/out/$MODEL/boot.img ] && cp build/out/$MODEL/boot.img "$AK3_DIR/"
    [ -f build/out/$MODEL/dtbo.img ] && cp build/out/$MODEL/dtbo.img "$AK3_DIR/"
    [ -f build/out/$MODEL/vendor_boot.img ] && cp build/out/$MODEL/vendor_boot.img "$AK3_DIR/"

    [[ "$MODEL" != "t2s" ]] && sed -i "s/^device\.name1=.*/device.name1=$MODEL/" "$AK3_DIR/anykernel.sh"

    pushd "$AK3_DIR" > /dev/null

    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' ../arch/arm64/configs/exynos2100_defconfig | cut -d '"' -f 2)
    version=${version:1}
    DATE=$(date +"%d-%m-%Y_%H-%M-%S")

    if [[ "$KSU_OPTION" == "y" && "$SUSFS_OPTION" == "y" ]]; then
        NAME="${version}_${MODEL}_KSUN_SUSFS_OFFICIAL_${DATE}.zip"
    elif [[ "$KSU_OPTION" == "y" ]]; then
        NAME="${version}_${MODEL}_KSUN_OFFICIAL_${DATE}.zip"
    else
        NAME="${version}_${MODEL}_VANILLA_OFFICIAL_${DATE}.zip"
    fi

    zip -r9 "../build/out/$MODEL/$NAME" * -x ".git*" "README.md" "*placeholder" || abort
    popd > /dev/null
}

KCONFIG_FILE="drivers/Kconfig"
KSU='source "drivers/kernelsu/Kconfig"'
MAKEFILE="drivers/Makefile"
MAKEFILE_LINE='obj-$(CONFIG_KSU) += kernelsu/'

if [[ "$KSU_OPTION" == "y" ]]; then

    fetch_ksu

    if [[ "$SUSFS_OPTION" == "y" ]]; then
        enable_susfs
    fi

    if ! grep -Fxq "$KSU" "$KCONFIG_FILE"; then
        sed -i "\|endmenu|i $KSU" "$KCONFIG_FILE"
    fi

    if ! grep -Fxq "$MAKEFILE_LINE" "$MAKEFILE"; then
        echo "$MAKEFILE_LINE" >> "$MAKEFILE"
    fi

else

    fetch_ksu

    sed -i "\|$KSU|d" "$KCONFIG_FILE"
    sed -i "\|$MAKEFILE_LINE|d" "$MAKEFILE"
fi

build_kernel
build_boot
build_dtb
build_modules

if [ -z "$RECOVERY" ]; then
    build_vendor_boot
    build_zip
fi

popd > /dev/null
echo "-----------------------------------------------"
echo "Build finished successfully!"