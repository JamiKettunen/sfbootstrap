# sfbootstrap env for oneplus-cheeseburger
VENDOR=oneplus
DEVICE=cheeseburger
VENDOR_PRETTY="OnePlus"
DEVICE_PRETTY="OnePlus 5 (A5000)"
PORT_ARCH=aarch64
SOC=qcom
PORT_TYPE=hybris
HYBRIS_VER=16.0
HAL_MAKE_TARGETS=(hybris-hal droidmedia libbiometry_fp_api)
RELEASE=4.3.0.12
#TOOLING_RELEASE=$RELEASE
SDK_RELEASE=3.7.4
REPOS_COMMON=(
    # OnePlus 5/5T common HAL
    'https://github.com/sailfishos-oneplus5/android_device_oneplus_msm8998-common.git' device/oneplus/msm8998-common "lineage-$HYBRIS_VER" 1
    'https://github.com/sailfishos-oneplus5/android_kernel_oneplus_msm8998.git' kernel/oneplus/msm8998 "lineage-$HYBRIS_VER" 1
    'https://github.com/sailfishos-oneplus5/proprietary_vendor_oneplus_msm8998.git' vendor/oneplus "lineage-$HYBRIS_VER" 1
    # SFOS misc
    'https://github.com/mer-hybris/libhybris.git' external/libhybris '' 0
    'https://github.com/sailfishos-oneplus5/hybris-boot.git' hybris/hybris-boot 'custom' 1
    'https://github.com/sailfishos-oneplus5/hybris-installer.git' hybris/hybris-installer '' 1
    'https://github.com/sailfishos-open/sailfish-fpd-community.git' hybris/mw/sailfish-fpd-community '' 1
)
REPOS=(
    # Shared between 5/5T
    "${REPOS_COMMON[@]}"
    # OnePlus 5 HAL
    'https://github.com/LineageOS/android_device_oneplus_cheeseburger.git' device/oneplus/cheeseburger "lineage-$HYBRIS_VER" 1
    # SFOS adaptation
    'https://github.com/sailfishos-oneplus5/droid-hal-cheeseburger.git' rpm '' 0
    'https://github.com/sailfishos-oneplus5/droid-config-cheeseburger.git' hybris/droid-configs '' 0
    'https://github.com/sailfishos-oneplus5/droid-hal-version-cheeseburger.git' hybris/droid-hal-version-cheeseburger '' 0
)
REPO_OVERRIDES=(
    # This project's path is already cloned to above
    'mer-hybris/hybris-boot'
)
LINKS=(
    'Sources' 'https://github.com/sailfishos-oneplus5'
    'Mer Wiki' 'https://wiki.merproject.org/wiki/Adaptations/libhybris/Install_SailfishOS_for_cheeseburger-dumpling'
    'XDA post' 'https://forum.xda-developers.com/t/rom-gnu-linux-ota-3-4-0-24-sailfish-os-for-oneplus-5.4036341/'
)
export VENDOR DEVICE PORT_ARCH RELEASE
