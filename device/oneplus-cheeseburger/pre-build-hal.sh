# Avoid pointless install of ImageMagick in HA build chroot
rm -rf "$ANDROID_ROOT/vendor/lineage/bootanimation"

# AudioPolicyService is needed to avoid camera HAL dying after attempting to record video
if ! grep -q 'AUDIOPOLICYSERVICE' "$ANDROID_ROOT/external/droidmedia/env.mk"; then
    echo "MINIMEDIA_AUDIOPOLICYSERVICE_ENABLE := 1" > "$ANDROID_ROOT/external/droidmedia/env.mk"
fi
