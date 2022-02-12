#!/usr/bin/env bash
# sfbootstrap - The all-in-one Sailfish OS local development bootstrapping script

# Config
#########
: ${SUDO:=sudo}          # sudo program, unset if running as root
: ${SFB_DEBUG:=0}        # enable debug mode (sfb_dbg)
: ${SFB_COLORS:=1}       # enable colorful output
: ${SFB_JOBS:=$(nproc)}  # amounts of sync/builds jobs to use
: ${SFB_ROOT:="$(readlink -f "$(dirname "$0")")"}
: ${PLATFORM_SDK_ROOT:="$SFB_ROOT/chroot"}

# Constants
############
SFB_LATEST_SFOS_RELEASE="4.3.0.12"
SFB_SUPPORTED_HYBRIS_VERS="10.1 11.0 12.1 13.0 14.1 15.1 16.0 17.1 18.1"
SFB_KNOWN_CONFIG_VARS=(
	ANDROID_MAJOR_VERSION DEVICE HABUILD_DEVICE HAL_MAKE_TARGETS HAL_ENV_EXTRA HYBRIS_VER PORT_ARCH PORT_TYPE
	RELEASE REPOS REPO_INIT_URL SOC TOOLING_RELEASE SDK_RELEASE VENDOR REPO_LOCAL_MANIFESTS_URL VENDOR_PRETTY
	DEVICE_PRETTY HOOKS_DEVICE LINKS REPO_OVERRIDES HYBRIS_PATCHER_SCRIPTS
)
SFB_YESNO_REGEX="^([yY].*|[nN].*|)$"
SFB_PRETTYNAME_REGEX="^[a-zA-Z0-9\ \(\)+-]+$"

# Runtime vars
###############
SFB_HOOKS=({pre,post}-{chroot-{setup,enter},build-{hal,packages,dhd,dcd,mw,gg,dhv,image}})
SFB_IMAGES="" # e.g. "$SFB_ROOT/images/$VENDOR-$DEVICE-$PORT_ARCH"
SFB_LASTDEVICE=""
SFB_LOCAL_MANIFESTS="" # e.g. "$ANDROID_ROOT/.repo/local_manifests"
SFB_OVERRIDES_XML="" # e.g. "$SFB_LOCAL_MANIFESTS/sfbootstrap-overrides.xml"
SFOSSDK_ROOT="$PLATFORM_SDK_ROOT/sdks/sfossdk"
HABUILD_ROOT="$PLATFORM_SDK_ROOT/sdks/ubuntu"
SB2_TOOLING_ROOT=""
SB2_TARGET_ROOT=""
ANDROID_ROOT="" # e.g. "$SFB_ROOT/src/hybris-18.1"
ANDROID_PRODUCT_OUT="" # e.g. "$ANDROID_ROOT/out/target/product/$HABUILD_DEVICE"

# Functions
############

# I/O
sfb_printf() { printf "${SFB_C_LBLUE}>>${SFB_C_RESET} $1"; }
sfb_log() { sfb_printf "$1\n"; }
sfb_exit() {
	[ "$1" ] && echo -e "$1" 1>&2
	exit ${2:-1}
}
sfb_error() { sfb_exit "${SFB_C_LRED}ERROR: $*${SFB_C_RESET}"; }
sfb_warn() { echo -e "${SFB_C_YELLOW}WARN: $*${SFB_C_RESET}" 1>&2; }
sfb_dbg() {
	if [ $SFB_DEBUG -eq 1 ]; then
		echo -e "${SFB_C_DIM}[DEBUG] $(caller 0 | awk '{printf "%s:%d",$2,$1}'): $1${SFB_C_RESET}" 1>&2
	fi
}
sfb_prompt() {
	local msg="$1" var="$2" match_regex="$3" prefill_ans="$4" loop=true
	while $loop; do
		if [ "$prefill_ans" ]; then
			sfb_log "$1 $prefill_ans ${SFB_C_DIM}(prefilled answer)${SFB_C_RESET}"
			eval "$var=$prefill_ans"
		else
			read -erp "$(printf "${SFB_C_LBLUE}>>${SFB_C_RESET}") $1 " $var
		fi
		if [ "$match_regex" ]; then
			if [[ "${!var}" =~ $match_regex ]]; then
				loop=false
			else
				echo -e "${SFB_C_LRED}Invalid input, didn't match expected regex '$match_regex'!${SFB_C_RESET}"
				if [ "$prefill_ans" ]; then
					sfb_exit
				fi
			fi
		else
			loop=false
		fi
	done
	sfb_dbg "$var='${!var}'"
}

# Device
sfb_get_droid_major_ver() {
	local hybris_major=${HYBRIS_VER%.*}
	if [ $hybris_major -gt 10 ]; then
		echo "$(($hybris_major-7))"
	else
		echo "4"
	fi
}
sfb_device_new() {
	SFB_DEVICE="$VENDOR-$DEVICE"
	local device_dir="$SFB_ROOT/device/$SFB_DEVICE" i branch
	[ -d "$device_dir" ] || mkdir -p "$device_dir"
	{
		echo "# sfbootstrap env for $SFB_DEVICE
VENDOR=$VENDOR
VENDOR_PRETTY=\"$VENDOR_PRETTY\"
DEVICE=$DEVICE
DEVICE_PRETTY=\"$DEVICE_PRETTY\"
#HABUILD_DEVICE=\$DEVICE
#HOOKS_DEVICE=\$SFB_DEVICE
PORT_ARCH=$PORT_ARCH
SOC=$SOC
PORT_TYPE=$PORT_TYPE"
		if [ "$PORT_TYPE" = "hybris" ]; then
			echo "HYBRIS_VER=$HYBRIS_VER
#ANDROID_MAJOR_VERSION=$(sfb_get_droid_major_ver)
#REPO_INIT_URL=\"https://github.com/mer-hybris/android.git\"
#REPO_LOCAL_MANIFESTS_URL=\"\"
#REPO_OVERRIDES=()
#HYBRIS_PATCHER_SCRIPTS=()
#HAL_MAKE_TARGETS=(hybris-hal droidmedia)
#HAL_ENV_EXTRA=\"\""
		fi
		echo "RELEASE=$RELEASE
#TOOLING_RELEASE=\$RELEASE
#SDK_RELEASE=latest"
		if [ ${#REPOS[@]} -gt 0 ]; then
			echo "REPOS=("
			for i in $(seq 0 4 $((${#REPOS[@]}-1))); do
				branch="${REPOS[$(($i+2))]}"
				if [ "$PORT_TYPE" = "hybris" ]; then
					branch="${branch//$HYBRIS_VER/\$HYBRIS_VER}"
				fi
				echo "    '${REPOS[$i]}' ${REPOS[$(($i+1))]} \"$branch\" ${REPOS[$(($i+3))]}"
			done
			echo ")"
		else
			echo "#REPOS=()"
		fi
		echo "#LINKS=()
export VENDOR DEVICE PORT_ARCH RELEASE"
	} > "$device_dir/env.sh"
}
save_lastdevice() { echo "$SFB_DEVICE" > "$SFB_ROOT"/.lastdevice; }
rm_lastdevice() { rm -f "$SFB_ROOT"/.lastdevice; }
sfb_device_env() {
	SFB_DEVICE="$1"
	local device_dir="$SFB_ROOT/device/$SFB_DEVICE" src_dir
	if [ ! -e "$device_dir/env.sh" ]; then
		sfb_error "Device '$SFB_DEVICE' doesn't have an existing port yet; check out '$0 init'!"
	fi
	pushd "$device_dir" >/dev/null
	. env.sh
	popd >/dev/null
	: ${TOOLING_RELEASE:=$RELEASE}
	: ${SDK_RELEASE:=latest}
	if [ "$PORT_TYPE" = "hybris" ]; then
		src_dir="hybris-$HYBRIS_VER"
		: ${ANDROID_MAJOR_VERSION:=$(sfb_get_droid_major_ver)}
		: ${HABUILD_DEVICE:=$DEVICE}
		: ${HOOKS_DEVICE:=$SFB_DEVICE}
		: ${HAL_MAKE_TARGETS:=hybris-hal droidmedia}
		: ${REPO_INIT_URL:=https://github.com/mer-hybris/android.git}
		if [ $ANDROID_MAJOR_VERSION -ge 9 ]; then
			HYBRIS_PATCHER_SCRIPTS=(
				"hybris-patches/apply-patches.sh --mb" "grep -q droid-hybris system/core/init/init.cpp"
				"${HYBRIS_PATCHER_SCRIPTS[@]}"
			)
		fi
	else
		src_dir="native"
	fi
	export ANDROID_ROOT="$SFB_ROOT/src/$src_dir"
	ANDROID_PRODUCT_OUT="$ANDROID_ROOT/out/target/product/$HABUILD_DEVICE"
	SFB_LOCAL_MANIFESTS="$ANDROID_ROOT/.repo/local_manifests"
	SFB_OVERRIDES_XML="$SFB_LOCAL_MANIFESTS/sfbootstrap-overrides.xml"
	SB2_TOOLING_ROOT="$PLATFORM_SDK_ROOT/toolings/SailfishOS-$TOOLING_RELEASE"
	SB2_TARGET_ROOT="$PLATFORM_SDK_ROOT/targets/$VENDOR-$DEVICE-$PORT_ARCH"
	SFB_IMAGES="$SFB_ROOT/images/$VENDOR-$DEVICE-$PORT_ARCH"
	[ -d "$ANDROID_ROOT" ] || mkdir -p "$ANDROID_ROOT"
	if [ "$SFB_DEVICE" != "$SFB_LASTDEVICE" ]; then
		# we don't want to save the device yet in case one of these fails, yet
		# sfb_chroot_sb2_setup() requires lastdevice to be saved for the
		# self-test to not fail!
		save_lastdevice
		trap rm_lastdevice EXIT
		if sfb_chroot_exists_sfossdk && ! sfb_chroot_exists_sb2_target; then
			sfb_chroot_sb2_setup
		fi
		sfb_sync_extra_repos
		trap - EXIT
	else
		save_lastdevice
	fi
}
sfb_env_reset() {
	local repos=$((${#REPOS[@]}/4)) i dir_local dir branch state known_vars="${SFB_KNOWN_CONFIG_VARS[*]}"
	if [ -d "$ANDROID_PRODUCT_OUT" ]; then
		sfb_log "Removing ANDROID_PRODUCT_OUT for $HABUILD_DEVICE, please wait..."
		rm -rf "$ANDROID_PRODUCT_OUT"
	fi

	if sfb_manual_hybris_patches_applied; then
		sfb_log "Unapplying found patches to hybris tree, please wait..."
		sfb_chroot habuild "repo sync -l" || sfb_error "Failed to run 'repo sync -l'!"
	fi

	if [ $repos -gt 0 ]; then
		sfb_log "Removing directories of $repos repos, please wait..."
	fi
	# repo parts => 0:url 1:dir 2:branch 3:is_shallow
	for i in $(seq 0 4 $((${#REPOS[@]}-1))); do
		dir_local="${REPOS[$(($i+1))]}"
		dir="$ANDROID_ROOT/$dir_local"
		[ -d "$dir" ] || continue # only operate on existing local repo clones

		branch=${REPOS[$(($i+2))]}
		state="$(sfb_local_repo_state "$dir" "$branch")"
		case "$state" in
			up-to-date|behind) : ;; # safe to delete
			*) sfb_error "Refusing to remove '$dir_local' in a state of '$state'!" ;;
		esac
		sfb_dbg "removing $dir_local..."
		rm -rf "$dir"
	done

	rm_lastdevice
	unset $known_vars SB2_TOOLING_ROOT SB2_TARGET_ROOT ANDROID_ROOT ANDROID_PRODUCT_OUT SFB_DEVICE
	REPOS=() LINKS=() REPO_OVERRIDES=() HYBRIS_PATCHER_SCRIPTS=()
}
sfb_get_devices() { find "$SFB_ROOT"/device/* -maxdepth 0 -type d -printf '%f\n' 2>/dev/null; }
sfb_pick_device() {
	local device devices=() i=0 max_i
	echo
	for device in $(sfb_get_devices); do
		i=$(($i+1))
		echo "   $i. $device"
		devices+=($device)
	done
	echo -e "   n. Add new device\n"
	max_i=$i
	device=""
	while [ -z $device ]; do
		sfb_prompt "Choose (1-$max_i/n):" i "^([1-9]|[1-9][0-9]+|[nN])$"
		if [ "${i^}" = "N" ]; then
			sfb_device_setup
			return
		fi
		device="${devices[$(($i-1))]}"
	done
	sfb_device_env $device
}
sfb_device_setup() {
	sfb_prompt "Device vendor (e.g. lg):" VENDOR "^[a-z]+$"
	sfb_prompt "Pretty form vendor name (e.g. LG):" VENDOR_PRETTY "$SFB_PRETTYNAME_REGEX"
	sfb_prompt "Device board name (e.g. hammerhead):" DEVICE "^[a-z0-9]+$"
	sfb_prompt "Pretty form device name (e.g. Nexus 5):" DEVICE_PRETTY "$SFB_PRETTYNAME_REGEX"
	sfb_prompt "Device architecture (aarch64/armv7hl/i486):" PORT_ARCH "^(aarch64|armv7hl|i486)$"
	sfb_prompt "Device SoC (qcom/exynos/mediatek/intel/other):" SOC "^(qcom|exynos|mediatek|intel|other)$"
	sfb_prompt "Port type (hybris/native):" PORT_TYPE "^(hybris|native)$"
	if [ "$PORT_TYPE" = "hybris" ]; then
		sfb_prompt "Hybris version (${SFB_SUPPORTED_HYBRIS_VERS// //}):" \
			HYBRIS_VER "^(${SFB_SUPPORTED_HYBRIS_VERS// /|})$"
	fi
	sfb_prompt "Target Sailfish OS release (e.g. $SFB_LATEST_SFOS_RELEASE):" RELEASE "^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$"
	local ans
	sfb_prompt "Add extra repositories to clone (y/N)?" ans "$SFB_YESNO_REGEX"
	if [[ "${ans^^}" = "Y"* ]]; then
		sfb_log "Adding extra repositories; enter nothing as the URL or directory at any point to stop!
"
		local url dir branch is_shallow
		while true; do
			sfb_prompt "Repo URL:" url
			[ -z $url ] && break
			sfb_prompt "Clone directory:" dir
			[ -z $dir ] && break
			sfb_prompt "Clone branch:" branch
			sfb_prompt "Shallow clone (y/N)?" ans "$SFB_YESNO_REGEX"
			[[ "${ans^^}" = "Y"* ]] && is_shallow=1 || is_shallow=0
			REPOS+=("$url" "$dir" "$branch" "$is_shallow")
			echo
		done
	fi
	sfb_device_new
	sfb_device_env $SFB_DEVICE
}
sfb_init() {
	local arg ans unknown_args=()
	for arg in "$@"; do
		case $arg in
			-y|--yes) ans="y" ;;
			*) unknown_args+="$arg" ;;
		esac
		shift
	done
	set -- "${unknown_args[@]}"
	if [ "$DEVICE" ]; then
		sfb_prompt "Reset build env for $SFB_DEVICE (y/N)?" ans "$SFB_YESNO_REGEX" "$ans"
		[[ "${ans^^}" != "Y"* ]] && return
	fi
	sfb_env_reset

	if [ $(sfb_get_devices | wc -l) -gt 0 ]; then
		if [ "$1" ]; then
			sfb_device_env "$1"
		else
			sfb_pick_device
		fi
	else
		sfb_device_setup
	fi
	sfb_log "Environment now setup for $SFB_DEVICE."
}

# Util
sfb_checkhost() {
	local hostkern="$(uname -s)" hostarch="$(uname -m)"
	if [ "$hostkern" != "Linux" ]; then
		sfb_error "Your host kernel $hostkern isn't supported (only Linux is)!"
	elif [ "$hostarch" != "x86_64" ]; then
		sfb_error "Your host CPU architecture $hostarch isn't supported (only x86_64 is)!"
	fi
}
sfb_setupvars() {
	[ $EUID -eq 0 ] && unset SUDO
	# colors
	if [ $SFB_COLORS -eq 1 ]; then
		SFB_C_LBLUE="\e[96m" SFB_C_LRED="\e[91m" SFB_C_GREEN="\e[32m" \
			SFB_C_YELLOW="\e[33m" SFB_C_RESET="\e[0m" SFB_C_DIM="\e[2m"
	fi
	if [ -r "$SFB_ROOT"/.lastdevice ]; then
		SFB_LASTDEVICE="$(<"$SFB_ROOT"/.lastdevice)"
	fi
}
sfb_setupdevice() {
	if [ -z "$SFB_LASTDEVICE" ]; then
		return # no previously chosen device to setup env for
	fi
	if [ ! -e "$SFB_ROOT/device/$SFB_LASTDEVICE/env.sh" ]; then
		rm_lastdevice
		sfb_error "Last device '$SFB_LASTDEVICE' doesn't have a port anymore; check out '$0 init'!"
	fi
	sfb_device_env "$SFB_LASTDEVICE"
}
sfb_checkdeps() {
	local dep missing=()
	for dep in git chroot wget bzip2; do
		if [ ! -x "$(command -v $dep)" ]; then
			missing+=($dep)
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		sfb_error "Your host machine is missing the following dependencies (${#missing[@]}):

   ${missing[*]}

Please install these via your package manager before continuing!"
	fi
}
sfb_list_modules() { find "$SFB_ROOT"/modules/* -maxdepth 0 -type f -name '*.sh' -printf '%f\n'; }
sfb_load_modules() {
	local module module_name f1 f2 funcs setup_usage
	if [ ! -d "$SFB_ROOT"/modules ]; then
		return # no modules dir
	fi

	for module in $(sfb_list_modules); do
		f1="$(declare -F)"
		. "$SFB_ROOT/modules/$module"
		f2="$(declare -F)"
		funcs=$(comm -13 <(echo "$f1" ) <(echo "$f2") | wc -l)
		[ -z "$module_name" ] && module_name="${module%.sh}"
		setup_usage="sfb_${module_name}_setup_usage"
		if declare -F "$setup_usage" >/dev/null; then
			"$setup_usage"
		fi
		sfb_dbg "loaded module $module_name with $funcs functions"
		unset module_name
	done
}
sfb_array_contains() {
	local item match_regex="$1"
	shift
	for item; do [[ "$item" =~ $match_regex ]] && return 0; done
	return 1
}
sfb_hook_exec() {
	local hook_name="$1" hook_path="$SFB_ROOT/device/$HOOKS_DEVICE/$1.sh"
	shift
	if ! sfb_array_contains "^$hook_name$" "${SFB_HOOKS[@]}"; then
		sfb_error "Hook '$hook_name' is unknown!"
	fi
	if [ -f "$hook_path" ]; then
		sfb_dbg "Executing hook '$hook_name'..."
		(. "$hook_path" "$@") || sfb_error "Failed to run $hook_name hook for $SFB_DEVICE!"
	fi
}
sfb_manual_hybris_patches_applied() {
	local i script patch_cmd applied_check_cmd
	for i in $(seq 0 2 $((${#HYBRIS_PATCHER_SCRIPTS[@]}-1))); do
		patch_cmd="${HYBRIS_PATCHER_SCRIPTS[$i]}"
		script="${patch_cmd%% *}" # drop args
		if [ ! -e "$ANDROID_ROOT/$script" ]; then
			sfb_dbg "hybris patcher script '$script' doesn't exist"
			continue
		fi
		applied_check_cmd="${HYBRIS_PATCHER_SCRIPTS[$(($i+1))]}"
		(eval "$applied_check_cmd") && return true
	done
}
sfb_link() {
	local url="$1" label="${2:-$1}"
	echo -e "\e]8;;$url\a$label\e]8;;\a"
}
sfb_sha256_file() { sha256sum "$1" | awk '{print $1}'; }
sfb_sha256() { echo -e "$1" | sha256sum | awk '{print $1}'; }
sfb_write_if_different() {
	local content="$1" file="$2" write=true old_sum new_sum dir
	if [ -f "$file" ]; then
		old_sum="$(sfb_sha256_file "$file")"
		new_sum="$(sfb_sha256 "$content")"
		[ "$old_sum" = "$new_sum" ] && write=false
	fi
	if $write; then
		sfb_dbg "writing $file..."
		dir="$(dirname "$file")"
		[ -d "$dir" ] || mkdir -p "$dir"
		echo -e "$content" > "$file"
	fi
}

# Misc
sfb_hook_status() {
	local hook="$1" path
	path="$SFB_ROOT/device/$HOOKS_DEVICE/$hook.sh"
	if [ -f "$path" ]; then
		printf "${SFB_C_GREEN}$(sfb_link "file://$path" "$hook")${SFB_C_RESET}"
	else
		printf "${SFB_C_LRED}$hook${SFB_C_RESET}"
	fi
}
sfb_dir_update_date() {
	local dir="${1:-$PWD}" format="${2:-%Y-%m-%d %-H:%M %Z}"
	date -d @$(find "$dir" -not -type d -printf '%T@\n' | sort -n | tail -1) +"$format"
}
sfb_status() {
	local repos=$((${#REPOS[@]}/4)) hook_count=${#SFB_HOOKS[@]} i max_i hook hook2 hook2_offset=0 \
		hook_len hook_len_max=0 links=$((${#LINKS[@]}/2)) link_label link_url
	printf "sfbootstrap port config:

   device:    $SFB_DEVICE"
	[[ "$HABUILD_DEVICE" != "$DEVICE" ]] && printf " ($HABUILD_DEVICE)"
	echo " | $VENDOR_PRETTY ${DEVICE_PRETTY#"$VENDOR_PRETTY "}
   arch:      $PORT_ARCH
   soc:       $SOC
   type:      $PORT_TYPE"
	if [ "$PORT_TYPE" = "hybris" ]; then
		echo "   hybris:    $HYBRIS_VER (Android $ANDROID_MAJOR_VERSION)"
	fi
	printf "   release:   $RELEASE"
	[ "$TOOLING_RELEASE" != "$RELEASE" ] && printf " (tooling: $TOOLING_RELEASE)"
	echo "
   sdk:       $SDK_RELEASE"
	if [ $repos -gt 0 ]; then
		printf "   repos:     $repos"
		if [ ${#REPO_OVERRIDES[@]} -gt 0 ]; then
			printf " (${#REPO_OVERRIDES[@]} overrides)"
		fi
		echo
	fi
	if [ "$REPO_LOCAL_MANIFESTS_URL" ]; then
		echo "   manifests: $REPO_LOCAL_MANIFESTS_URL"
	fi
	echo "   updated:   $(sfb_dir_update_date "$SFB_ROOT/device/$SFB_DEVICE")
   hooks:"
	for i in $(seq 0 $(($hook_count-1))); do
		hook="${SFB_HOOKS[$i]}"
		hook_len=${#hook}
		[ $hook_len -gt $hook_len_max ] && hook_len_max=$hook_len
	done
	if [ $(($hook_count%2)) -eq 1 ]; then
		hook2_offset=1
	fi
	max_i=$(($hook_count/2))
	for i in $(seq 0 $max_i); do
		[[ $i -eq $max_i && $hook2_offset -eq 0 ]] && continue
		hook="${SFB_HOOKS[$i]}"
		hook_len=${#hook}
		hook2="${SFB_HOOKS[$(($hook_count/2+$i+$hook2_offset))]}"
		printf "     $(sfb_hook_status "$hook")%$(($hook_len_max-$hook_len+7))s$(sfb_hook_status "$hook2")\n"
	done
	if [ $links -gt 0 ]; then
		echo "   links:"
		for i in $(seq 0 2 $((${#LINKS[@]}-1))); do
			link_label="${LINKS[$i]}"
			link_url="${LINKS[$(($i+1))]}"
			if  [ "$link_label" ]; then
				echo "     $link_label: $link_url"
			else
				echo "     $link_url"
			fi
		done
		echo
	else
		echo
	fi
}
sfb_config() {
	local var="$1" value declare_var known_vars="${SFB_KNOWN_CONFIG_VARS[*]}"
	if [ -z "$var" ]; then
		sfb_log "sfbootstrap variables available:"
		compgen -v | while read var; do
			[[ "$var" =~ ^[A-Z_]+$ ]] || continue
			eval "case $var in
				SFB_C_*) continue ;; # skip color constants
				SB2_TOOLING_ROOT|SB2_TARGET_ROOT|ANDROID_ROOT|ANDROID_PRODUCT_OUT|PLATFORM_SDK_ROOT|SFOSSDK_ROOT|HABUILD_ROOT|SFB_*|SUDO|${known_vars// /|}) : ;;
				*) sfb_dbg \"skipped var=$var\"; continue ;; # skip others
			esac"
			declare_var="$(declare -p $var)"
			if [[ "$declare_var" =~ "declare -a" ]]; then
				echo "${declare_var#declare -a }"
			else
				value=${!var}
				if [[ "$value" =~ ^[0-9]+$ ]]; then
					echo "$var=$value"
				else
					echo "$var=\"$value\""
				fi
			fi
		done
		return
	fi

	value="${!var}"
	if [ "$value" ]; then # ${!var+x}
		echo "$value"
	else
		sfb_error "Variable '$var' has no value set!"
	fi
}
sfb_show_usage() {
	local module="${1:-main}" funcs_var funcs_arr funcs_items i func func_len func_len_max=0 usage \
	      fi args_var args_arr ai arg arg_len arg_len_max=0 arg_printed_header=0
	funcs_var=sfb_usage_$module # e.g. "sfb_usage_build"
	declare -n funcs_arr=$funcs_var
	if [ ${#funcs_arr[@]} -eq 0 ]; then
		sfb_dbg "skipped funcs_arr=$funcs_var"
		return
	fi

	funcs_items="$(seq 0 2 $((${#funcs_arr[@]}-1)))"
	for i in $funcs_items; do
		func="${funcs_arr[$i]}"
		func_len=${#func}
		[ $func_len -gt $func_len_max ] && func_len_max=$func_len
	done

	for i in $funcs_items; do
		func="${funcs_arr[$i]}"
		usage="${funcs_arr[$(($i+1))]}"
		echo "  $(printf "%-${func_len_max}s" "$func")  $usage"
	done

	for fi in $funcs_items; do
		func="${funcs_arr[$fi]}"
		args_var=sfb_usage_${module}_${func}_args # e.g. "sfb_usage_chroot_setup_args"
		declare -n args_arr=$args_var
		if [ ${#args_arr[@]} -eq 0 ]; then
			sfb_dbg "skipped args_var=$args_var"
			continue
		fi

		for ai in $(seq 0 2 $((${#args_arr[@]}-1))); do
			arg="${args_arr[$ai]}"
			arg_len=${#arg}
			[ $arg_len -gt $arg_len_max ] && arg_len_max=$arg_len
		done
		if [ $arg_len_max -gt 0 ]; then
			arg_len_max=$(($arg_len_max+2))
		fi

		for ai in $(seq 0 2 $((${#args_arr[@]}-1))); do
			arg="${args_arr[$ai]}"
			usage="${args_arr[$(($ai+1))]}"
			if [ "$usage" ]; then
				if [ $arg_printed_header -eq 0 ]; then
					echo "
Arguments for $func:"
					arg_printed_header=1
				fi
				echo "  $(printf "%-${arg_len_max}s" "$arg")$usage"
			fi
		done
		arg_len_max=0; arg_printed_header=0 # reset per-function arg flags
	done
}
sfb_usage() {
	local func_name="$1" subfunc="${2:-$1}" usage
	if [ "$func_name" ]; then
		usage="$subfunc <subfunction> [args]

Subfunctions:"
	else
		func_name="main"
		usage="<function> [subfunction] [args]

Functions:"
	fi
	sfb_exit "usage: $0 $usage
$(sfb_show_usage $func_name)
"
}
sfb_main() {
	sfb_setupvars
	sfb_checkhost
	sfb_checkdeps
	sfb_load_modules
	sfb_setupdevice

	local func="sfb_$1"; shift
	if declare -F "$func" >/dev/null; then
		if [[ "$func" != "sfb_init" && -z "$SFB_DEVICE" ]]; then
			sfb_error "No target device is chosen; check out '$0 init'!"
		fi
		$func "$@" || sfb_error "Failed to complete ${func:4} function successfully!"
	else
		sfb_usage
	fi
}
sfb_usage_main=(
	init "Initialize environment for building against a specific device"
	status "Show information about the currently initialized device port"
	config "Get (port specific) variable values in sfbootstrap"
)
sfb_usage_main_init_args=(
	"-y|--yes" "Answer yes to reset build env question automatically"
	"" "[optional device name to initialize]"
)
sfb_usage_main_config_args=("" "[runtime variable name to print the value of]")

# Script
#########
sfb_main "$@"
