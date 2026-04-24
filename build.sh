#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORES="${CORES:-$(nproc)}"
MODEL="${MODEL:-}"
KSU_OPTION="${KSU_OPTION:-}"
SUSFS_OPTION="${SUSFS_OPTION:-}"
RECOVERY_OPTION="${RECOVERY_OPTION:-}"
KSU=""
SUSFS=""
RECOVERY=""

log() {
    echo "-----------------------------------------------"
    echo "$*"
    echo "-----------------------------------------------"
}

abort() {
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit 1
}

usage() {
    cat << 'USAGE_EOF'
Usage: build.sh [options]
Options:
    -m, --model [value]    Specify the model code of the phone: r9s/o1s/t2s/p3s
    -k, --ksu [y/N]        Include KernelSU Next
    -s, --susfs [y/N]      Include SuSFS
    -r, --recovery [y/N]   Compile kernel for an Android Recovery
USAGE_EOF
}

retry() {
    local max=3
    local delay=5
    local attempt=1

    until "$@"; do
        if (( attempt >= max )); then
            return 1
        fi
        echo "Command failed. Retry $attempt/$max in ${delay}s: $*"
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m) MODEL="${2:-}"; shift 2 ;;
        --ksu|-k) KSU_OPTION="${2:-}"; shift 2 ;;
        --susfs|-s) SUSFS_OPTION="${2:-}"; shift 2 ;;
        --recovery|-r) RECOVERY_OPTION="${2:-}"; shift 2 ;;
        *) usage; exit 1 ;;
    esac
done

cd "$ROOT_DIR"

if [[ -z "$MODEL" ]]; then
    usage
    exit 1
fi

case "$MODEL" in
    r9s) BOARD="SRPUG16A010KU" ;;
    o1s) BOARD="SRPTH19C011KU" ;;
    t2s) BOARD="SRPTG24B014KU" ;;
    p3s) BOARD="SRPTH19D013KU" ;;
    *) usage; exit 1 ;;
esac

if [[ "$RECOVERY_OPTION" == "y" ]]; then
    RECOVERY="recovery.config"
    KSU_OPTION="n"
    SUSFS_OPTION="n"
fi

if [[ -z "$KSU_OPTION" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Include KernelSU Next (y/N): " KSU_OPTION
    else
        KSU_OPTION="n"
    fi
fi

[[ "$KSU_OPTION" == "y" ]] && KSU="ksu.config"
[[ "$SUSFS_OPTION" == "y" ]] && SUSFS="susfs.config"

apply_fake_uptime_patch() {
    echo "=== Applying Fake Uptime Patch (12 days for o1s Exynos2100) ==="
    mkdir -p patches/uptime

    if [[ ! -f patches/uptime/0001-fake-uptime-12days.patch ]]; then
        cat > patches/uptime/0001-fake-uptime-12days.patch << 'PATCH_EOF'
diff --git a/kernel/time/timekeeping.c b/kernel/time/timekeeping.c
--- a/kernel/time/timekeeping.c
+++ b/kernel/time/timekeeping.c
@@ -90,6 +90,25 @@ static struct tk_fast tk_fast_mono ____cacheline_aligned;
 static struct timekeeper shadow_timekeeper;
 
+/* Fake Uptime Toàn Hệ Thống cho Exynos2100 (o1s) - ChicletKernel */
+static inline u64 get_fake_boottime_ns(void)
+{
+       static const u64 fake_days = 12ULL;
+       return fake_days * 86400ULL * 1000000000ULL;
+}
+
 static u64 timekeeping_get_delta(const struct tk_read_base *tkr)
 {
+       u64 delta = tk_clock_read(tkr) - tkr->cycle_last;
+       return delta + get_fake_boottime_ns();
+
        return tk_clock_read(tkr) - tkr->cycle_last;
 }
PATCH_EOF
    fi

    patch -p1 --forward --ignore-whitespace --no-backup-if-mismatch < patches/uptime/0001-fake-uptime-12days.patch 2>/dev/null || \
        echo "→ Patch đã được áp dụng trước đó hoặc có xung đột nhỏ (tiếp tục build)"
}

prepare_toolchain() {
    CLANG_DIR="$ROOT_DIR/toolchain/clang-r596125"
    export PATH="$CLANG_DIR/bin:$PATH"

    if [[ ! -x "$CLANG_DIR/bin/clang" && ! -x "$CLANG_DIR/bin/clang-22" ]]; then
        log "Toolchain not found. Downloading clang-r596125..."
        rm -rf "$CLANG_DIR"
        mkdir -p "$CLANG_DIR"
        pushd "$CLANG_DIR" >/dev/null
        retry curl -L --retry 3 --retry-delay 5 \
            -o clang-r596125.tar.gz \
            "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/mirror-goog-main-llvm-toolchain-source/clang-r596125.tar.gz" || abort
        tar xf clang-r596125.tar.gz || abort
        rm -f clang-r596125.tar.gz
        popd >/dev/null
    fi
}

fetch_ksu() {
    local repo="https://github.com/KernelSU-Next/KernelSU-Next.git"
    local dir="$ROOT_DIR/KernelSU-Next"

    rm -rf "$dir" "$ROOT_DIR/drivers/kernelsu"
    echo "Fetching latest KernelSU Next without recursive submodules..."

    retry git clone --depth=1 "$repo" "$dir" || {
        echo "Failed to clone KernelSU Next!"
        exit 1
    }

    if [[ -d "$dir/kernel" ]]; then
        ln -s ../KernelSU-Next/kernel "$ROOT_DIR/drivers/kernelsu"
    elif [[ -f "$dir/Kconfig" ]]; then
        ln -s ../KernelSU-Next "$ROOT_DIR/drivers/kernelsu"
    else
        echo "KernelSU Next layout not recognized. Missing kernel/Kconfig."
        exit 1
    fi
}

enable_susfs() {
    echo "Applying SuSFS patch to KernelSU Next..."
    patch -d "$ROOT_DIR/KernelSU-Next" -p1 < "$ROOT_DIR/patches/enable-susfs.patch" || {
        echo "Failed to apply SuSFS patch!"
        exit 1
    }
}

configure_ksu_entries() {
    local kconfig_file="drivers/Kconfig"
    local ksu_line='source "drivers/kernelsu/Kconfig"'
    local makefile="drivers/Makefile"
    local makefile_line='obj-$(CONFIG_KSU) += kernelsu/'

    if [[ "$KSU_OPTION" == "y" ]]; then
        fetch_ksu
        [[ "$SUSFS_OPTION" == "y" ]] && enable_susfs
        grep -Fxq "$ksu_line" "$kconfig_file" || sed -i "\|endmenu|i $ksu_line" "$kconfig_file"
        grep -Fxq "$makefile_line" "$makefile" || echo "$makefile_line" >> "$makefile"
    else
        rm -rf "$ROOT_DIR/KernelSU-Next" "$ROOT_DIR/drivers/kernelsu"
        sed -i "\|$ksu_line|d" "$kconfig_file"
        sed -i "\|$makefile_line|d" "$makefile"
    fi
}

MAKE_ARGS=(LLVM=1 LLVM_IAS=1 ARCH=arm64 O=out)

build_kernel() {
    log "Build config"
    echo "Model: $MODEL"
    echo "Board: $BOARD"
    echo "KSU: ${KSU:-N}"
    echo "SUSFS: ${SUSFS:-N}"
    echo "Recovery: ${RECOVERY:-N}"
    echo "Cores: $CORES"

    log "Generating configuration file"
    make "${MAKE_ARGS[@]}" -j"$CORES" exynos2100_defconfig "$MODEL.config" ${RECOVERY:+$RECOVERY} ${KSU:+$KSU} ${SUSFS:+$SUSFS} || abort

    log "Building kernel"
    make "${MAKE_ARGS[@]}" -j"$CORES" || abort
}

build_boot() {
    cp -a out/arch/arm64/boot/Image "build/out/$MODEL/"
    [[ -n "$RECOVERY" ]] && return 0

    log "Building boot.img RAMDisk"
    rm -rf "build/out/$MODEL/boot_ramdisk00"
    cp -a build/ramdisk/boot/boot_ramdisk00 "build/out/$MODEL/"

    pushd "build/out/$MODEL/boot_ramdisk00" >/dev/null
    find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | lz4 -l > ../boot_ramdisk || abort
    popd >/dev/null

    log "Building boot.img"
    python3 toolchain/mkbootimg/mkbootimg.py \
        --header_version 3 \
        --cmdline "androidboot.selinux=permissive loop.max_part=7" \
        --ramdisk "build/out/$MODEL/boot_ramdisk" \
        --os_version 16.0.0 \
        --os_patch_level 2025-11 \
        --kernel "build/out/$MODEL/Image" \
        --output "build/out/$MODEL/boot.img" || abort
}

build_dtb() {
    log "Building DTB image"
    ./toolchain/mkdtimg cfg_create "build/out/$MODEL/dtb.img" dt.configs/exynos2100.cfg -d out/arch/arm64/boot/dts/exynos || abort

    log "Building DTBO image"
    ./toolchain/mkdtimg cfg_create "build/out/$MODEL/dtbo.img" "dt.configs/$MODEL.cfg" -d "out/arch/arm64/boot/dts/samsung/$MODEL" || abort
}

build_modules() {
    local modules_folder="modules"
    local kernel_dir_path
    local kernel_version
    local remove_modules=(sec_debug_sched_info.ko)

    rm -rf "out/$modules_folder"
    log "Building modules"
    make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH="$modules_folder" INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" modules_install || abort

    for filename in "${remove_modules[@]}"; do
        find "out/$modules_folder" -type f -name "$filename" -delete
    done

    kernel_dir_path="$(find "out/$modules_folder/lib/modules" -maxdepth 1 -type d -name "5.4*" | head -n1)"
    [[ -n "$kernel_dir_path" ]] || abort
    kernel_version="$(basename "$kernel_dir_path")"

    depmod -a -b "out/$modules_folder" "$kernel_version" || abort
    sed -i 's/.*\///g' "$kernel_dir_path/modules.order"

    for filename in "${remove_modules[@]}"; do
        sed -i "/$filename/d" "$kernel_dir_path/modules.order"
    done

    : > "$kernel_dir_path/modules.load"

    local initial_order=(
        dss.ko exynos-chipid_v2.ko exynos-reboot.ko exynos2100-itmon.ko
        exynos-pmu-if.ko s3c2410_wdt.ko exynos-ecc-handler.ko debug-snapshot-qd.ko
        eat.ko exynos-adv-tracer-s2d.ko ehld.ko exynos-debug-test.ko hardlockup-debug.ko
        exynos_acpm.ko exynos_pm_qos.ko exynos-s2mpu.ko exynos-pd_el3.ko ect_parser.ko
        cmupmucal.ko clk_exynos.ko clk-exynos-audss.ko exynos_mct.ko pinctrl-samsung-core.ko
        exynos-cpupm.ko i2c-exynos5.ko acpm-mfd-bus.ko s2mps24_mfd.ko s2mps23_mfd.ko
        pmic_class.ko s2mps23-regulator.ko s2mps24-regulator.ko phy-exynos-usbdrd-super.ko
        sec_debug_mode.ko fingerprint.ko
    )

    for module in "${initial_order[@]}"; do
        echo "$module" >> "$kernel_dir_path/modules.load"
        sed -i "/^$module$/d" "$kernel_dir_path/modules.order"
    done

    cat "$kernel_dir_path/modules.order" >> "$kernel_dir_path/modules.load"
    sed -i 's/\(kernel\/[^: ]*\/\)\([^: ]*\.ko\)/\/lib\/modules\/\2/g' "$kernel_dir_path/modules.dep"

    mkdir -p "build/out/$MODEL/modules/lib/modules"
    find "$kernel_dir_path" -name '*.ko' -exec cp '{}' "build/out/$MODEL/modules/lib/modules" ';'
    cp "$kernel_dir_path"/modules.{alias,dep,softdep,load} "build/out/$MODEL/modules/lib/modules/"
}

build_vendor_boot() {
    log "Building vendor_boot RAMDisks"
    rm -rf "build/out/$MODEL/vendor_ramdisk00"
    cp -a build/ramdisk/vendor_boot/ramdisk00 "build/out/$MODEL/vendor_ramdisk00"
    cp -a "build/out/$MODEL/modules/lib/"* "build/out/$MODEL/vendor_ramdisk00/lib/"
    cp -a "build/ramdisk/vendor_boot/vendor_firmware/$MODEL/"* "build/out/$MODEL/vendor_ramdisk00/"

    pushd "build/out/$MODEL/vendor_ramdisk00" >/dev/null
    find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip -c > ../vendor_ramdisk || abort
    popd >/dev/null

    log "Building vendor_boot image"
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

build_zip() {
    log "Building AK3 zip"
    local ak3_dir="$ROOT_DIR/AnyKernel3"
    local ak3_repo="https://github.com/xfwdrev/AnyKernel3.git"
    local ak3_branch="t2s"

    if [[ ! -d "$ak3_dir/.git" ]]; then
        echo "AnyKernel3 not found. Cloning $ak3_branch branch..."
        retry git clone --depth=1 -b "$ak3_branch" "$ak3_repo" "$ak3_dir" || abort
    else
        echo "AnyKernel3 exists. Updating..."
        retry git -C "$ak3_dir" fetch --depth=1 origin "$ak3_branch" || abort
        git -C "$ak3_dir" checkout "$ak3_branch" || abort
        git -C "$ak3_dir" reset --hard "origin/$ak3_branch" || abort
        git -C "$ak3_dir" clean -fd || abort
    fi

    rm -f "$ak3_dir/boot.img" "$ak3_dir/vendor_boot.img" "$ak3_dir/dtbo.img"
    [[ -f "build/out/$MODEL/boot.img" ]] && cp "build/out/$MODEL/boot.img" "$ak3_dir/"
    [[ -f "build/out/$MODEL/dtbo.img" ]] && cp "build/out/$MODEL/dtbo.img" "$ak3_dir/"
    [[ -f "build/out/$MODEL/vendor_boot.img" ]] && cp "build/out/$MODEL/vendor_boot.img" "$ak3_dir/"

    [[ "$MODEL" != "t2s" ]] && sed -i "s/^device\.name1=.*/device.name1=$MODEL/" "$ak3_dir/anykernel.sh"

    pushd "$ak3_dir" >/dev/null
    local version
    local date_stamp
    local name

    version="$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' ../arch/arm64/configs/exynos2100_defconfig | cut -d '"' -f 2 || true)"
    version="${version#-}"
    [[ -n "$version" ]] || version="ChicletKernel"
    date_stamp="$(date +"%d-%m-%Y_%H-%M-%S")"

    if [[ "$KSU_OPTION" == "y" && "$SUSFS_OPTION" == "y" ]]; then
        name="${version}_${MODEL}_KSUN_SUSFS_OFFICIAL_${date_stamp}.zip"
    elif [[ "$KSU_OPTION" == "y" ]]; then
        name="${version}_${MODEL}_KSUN_OFFICIAL_${date_stamp}.zip"
    else
        name="${version}_${MODEL}_VANILLA_OFFICIAL_${date_stamp}.zip"
    fi

    zip -r9 "../build/out/$MODEL/$name" . -x ".git*" "README.md" "*placeholder" || abort
    popd >/dev/null
}

main() {
    log "Preparing the build environment"
    apply_fake_uptime_patch
    prepare_toolchain
    configure_ksu_entries

    rm -rf "build/out/$MODEL"
    mkdir -p "build/out/$MODEL/zip/files" "build/out/$MODEL/zip/META-INF/com/google/android"

    build_kernel
    build_boot
    build_dtb
    build_modules

    if [[ -z "$RECOVERY" ]]; then
        build_vendor_boot
        build_zip
    fi

    log "Build finished successfully"
}

main "$@"
