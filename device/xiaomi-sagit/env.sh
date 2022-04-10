# sfbootstrap env for xiaomi-sagit
VENDOR=xiaomi
DEVICE=sagit
VENDOR_PRETTY="Xiaomi"
DEVICE_PRETTY="Mi 6"
PORT_ARCH=aarch64
SOC=qcom
PORT_TYPE=hybris
HYBRIS_VER=17.1
HAL_MAKE_TARGETS=(hybris-hal droidmedia libbiometry_fp_api)
RELEASE=4.4.0.58
#TOOLING_RELEASE=$RELEASE
SDK_RELEASE=3.9.6
REPOS_COMMON=(
    # Xiaomi MI 6 common HAL
    'https://github.com/SailfishOS-sagit/android_device_xiaomi_msm8998-common.git' device/xiaomi/msm8998-common "hybris-$HYBRIS_VER" 1
    'https://github.com/SailfishOS-sagit/android_kernel_xiaomi_msm8998.git' kernel/xiaomi/msm8998 "hybris-$HYBRIS_VER" 1
    'https://github.com/SailfishOS-sagit/android_vendor_xiaomi.git' vendor/xiaomi "hybris-$HYBRIS_VER" 1
    # SFOS misc
    'https://github.com/SailfishOS-sagit/prebuilts_clang_host_linux-x86_clang-r407598.git' prebuilts/clang/host/linux-x86/clang-r407598 "11" 1
    'https://github.com/mer-hybris/libhybris.git' external/libhybris '' 0
    'https://github.com/sailfishos-sagit/hybris-boot.git' hybris/hybris-boot '' 1
    'https://github.com/sailfishos-sagit/hybris-installer.git' hybris/hybris-installer '' 1
    'https://github.com/sailfishos-open/sailfish-fpd-community.git' hybris/mw/sailfish-fpd-community '' 1
)
REPOS=(
    # Shared between sagit
    "${REPOS_COMMON[@]}"
    # Xiaomi MI 6 HAL
    'https://github.com/SailfishOS-sagit/android_device_xiaomi_sagit.git' device/xiaomi/sagit "lineage-$HYBRIS_VER" 1
    # SFOS adaptation
    'https://github.com/sailfishos-sagit/droid-hal-sagit.git' rpm "hybris-$HYBRIS_VER" 0
    'https://github.com/sailfishos-sagit/droid-config-sagit.git' hybris/droid-configs "hybris-$HYBRIS_VER" 0
    'https://github.com/sailfishos-sagit/droid-hal-version-sagit.git' hybris/droid-hal-version-sagit '' 0
)
REPO_OVERRIDES=(
    # This project's path is already cloned to above
    'mer-hybris/hybris-boot'
)
LINKS=(
    'Sources' 'https://github.com/sailfishos-sagit'
)
export VENDOR DEVICE PORT_ARCH RELEASE
