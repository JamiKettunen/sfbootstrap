module_name=build

SFB_BP="rpm/dhd/helpers/build_packages.sh"

sfb_build_hal_apply_patches() {
	local i patch_cmd script
	if sfb_manual_hybris_patches_applied; then
		return # already applied
	fi

	#sfb_hook_exec pre-build-patches
	for i in $(seq 0 2 $((${#HYBRIS_PATCHER_SCRIPTS[@]}-1))); do
		patch_cmd="${HYBRIS_PATCHER_SCRIPTS[$i]}"
		script="${patch_cmd%% *}" # drop args
		if [ ! -e "$ANDROID_ROOT/$script" ]; then
			sfb_dbg "hybris patcher script '$script' doesn't exist"
			continue
		fi
		sfb_log "Running '$patch_cmd'..."
		sfb_chroot habuild "$patch_cmd" || return 1
	done
	#sfb_hook_exec post-build-patches
}
sfb_build_hal() {
	local targets extra_cmds=""
	if [ "$PORT_TYPE" != "hybris" ]; then
		sfb_warn "Non-hybris port of type '$PORT_TYPE' doesn't require a HAL building!"
		return
	fi
	if [ ! -e "$ANDROID_ROOT/build/envsetup.sh" ]; then
		sfb_error "Sources for hybris-$HYBRIS_VER aren't synced!"
	fi
	[ $# -gt 0 ] && targets=($@) || targets=(${HAL_MAKE_TARGETS[*]})
	sfb_build_hal_apply_patches || sfb_error "Applying hybris patches failed!"
	sfb_hook_exec pre-build-hal
	sfb_log "Building HAL components '${targets[*]}' with $SFB_JOBS jobs for $HABUILD_DEVICE..."
	if [ $ANDROID_MAJOR_VERSION -ge 10 ]; then
		extra_cmds+=" && export TEMPORARY_DISABLE_PATH_RESTRICTIONS=true"
	fi
	if [ "$HAL_ENV_EXTRA" ]; then
		extra_cmds+=" && $HAL_ENV_EXTRA"
	fi
	sfb_chroot habuild ". build/envsetup.sh && breakfast $HABUILD_DEVICE$extra_cmds && make -j$SFB_JOBS ${targets[*]}" || return 1
	if sfb_array_contains "^libbiometry_fp_api" "${targets[@]}"; then
		sfb_log "Copying built sailfish-fpd-community HAL files..."
		sfb_chroot sfossdk sh -c 'hybris/mw/sailfish-fpd-community*/rpm/copy-hal.sh' || return 1
	fi
	if sfb_array_contains "^hwcrypt$" "${targets[@]}"; then
		sfb_log "Copying built hwcrypt HAL files..."
		sfb_chroot sfossdk sh -c 'hybris/mw/hwcrypt*/rpm/copy-hal.sh' || return 1
	fi
	sfb_hook_exec post-build-hal
}
sfb_build_kernel() { sfb_build_hal hybris-boot; }

sfb_move_artifacts() {
	local f
	if [ $(find "$ANDROID_ROOT/SailfishOS"* -type f -name '*.zip' 2>/dev/null | wc -l) -eq 0 ]; then
		return # no artifacts to move
	fi

	sfb_log "Moving flashable Sailfish OS artifacts under ${SFB_IMAGES#"$SFB_ROOT/"}..."
	[ -d "$SFB_IMAGES" ] || mkdir -p "$SFB_IMAGES"
	for f in $(find "$ANDROID_ROOT/SailfishOS"* -type f -name '*.zip'); do
		$SUDO chown $USER: "$f"*
		$SUDO mv "$f"* "$SFB_IMAGES"
	done
	sfb_log "Done!"
}
sfb_build_packages() {
	local cmd=()
	if [ ! -e "$ANDROID_ROOT/$SFB_BP" ]; then
		sfb_log "Device sources aren't properly setup (missing droid-hal-$DEVICE)!"
		return
	fi
	sfb_hook_exec pre-build-packages "$@"
	if [ $# -gt 0 ]; then
		cmd=($SFB_BP "$@")
		sfb_chroot sfossdk "${cmd[@]}" || return 1
	else
		sfb_hook_exec pre-build-dhd
		sfb_chroot sfossdk sh -c "$SFB_BP --droid-hal" || return 1
		sfb_hook_exec post-build-dhd
		sfb_hook_exec pre-build-dcd
		sfb_chroot sfossdk sh -c "$SFB_BP --configs" || return 1
		sfb_hook_exec post-build-dcd

		# Required to e.g. install droid-hal-version-$DEVICE & droidmedia on target
		sfb_chroot sfossdk sh -c "sb2 -t $VENDOR-$DEVICE-$PORT_ARCH -m sdk-install -R zypper -n install droid-config-$DEVICE"

		sfb_hook_exec pre-build-mw
		echo 'all' | sfb_chroot sfossdk sh -c "$SFB_BP --mw" || return 1
		sfb_hook_exec post-build-mw
		if [ "$PORT_TYPE" = "hybris" ]; then
			if [ -f "$ANDROID_PRODUCT_OUT/system/lib/libdroidmedia.so" ]; then
				sfb_log "Fetching tags for droidmedia..."
				git -C "$ANDROID_ROOT/external/droidmedia" fetch --all --tags
				sfb_hook_exec pre-build-gg
				sfb_chroot sfossdk sh -c "$SFB_BP --gg" || return 1
				sfb_hook_exec post-build-gg
			else
				sfb_log "Skipping build of droidmedia and supporting packages due to missing HAL bits"
			fi
		fi

		sfb_hook_exec pre-build-dhv
		sfb_chroot sfossdk sh -c "$SFB_BP --version" || return 1
		sfb_hook_exec post-build-dhv
		sfb_hook_exec pre-build-image
		sfb_chroot sfossdk sh -c "$SFB_BP --mic" || return 1
		sfb_hook_exec post-build-image
	fi
	sfb_move_artifacts
	sfb_hook_exec post-build-packages "$@"
}

sfb_build() {
	case "$1" in
		hal)
			shift; sfb_build_hal "$@" || sfb_error "Build of HAL has failed!" ;;
		kernel)
			shift; sfb_build_kernel || sfb_error "Build of kernel has failed!" ;;
		packages)
			shift; sfb_build_packages "$@" || sfb_error "Build of packages has failed!" ;;
		*)
			sfb_usage build ;;
	esac
}
sfb_build_setup_usage() {
	sfb_usage_main+=(build "Build HAL parts or SFOS components/images")
	sfb_usage_build=(
		hal "Build all required hybris HAL parts"
		kernel "Build just hybris-boot.img"
		packages "Invoke Sailfish OS SDK build_packages.sh"
	)
	sfb_usage_build_hal_args=("" "[optional custom make build target(s) to override HAL_MAKE_TARGETS]")
	sfb_usage_build_packages_args=("" "[args to optionally pass directly to sfossdk build_packages.sh script]")
}
