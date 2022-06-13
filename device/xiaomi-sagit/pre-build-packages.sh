# Attempt to utilize more than one CPU thread for builds
util="$ANDROID_ROOT/rpm/dhd/helpers/util.sh"
if ! grep -q 'build -j' "$util"; then
    sed 's/build >>/build -j $(nproc) >>/' -i "$util"
fi
