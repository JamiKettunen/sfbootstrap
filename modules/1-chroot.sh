module_name=chroot

SFB_ARC="$SFB_ROOT/archives"
SFB_SDK_URL="http://releases.sailfishos.org/sdk"

sfb_fetch() {
	local arg url file hashtype error=false fail_on_error=true dir filename \
	      hashcmd checksum_remote checksum_local fetch=1
	for arg in "$@"; do
		case "$1" in
			-u) url="$2"; shift ;;
			-o) file="$2"; shift ;;
			-c) hashtype="$2"; shift ;;
			-F) fail_on_error=false ;;
		esac
		shift
	done
	if [[ -z "$url" || -z "$file" ]]; then
		sfb_error "A specified URL and output file are required to fetch web content!"
	fi
	dir="$(readlink -f "$(dirname "$file")")"
	[ -d "$dir" ] || mkdir -p "$dir"
	filename="$(basename "$file")"
	if [[ -f "$file" && "$hashtype" ]]; then
		checksum_remote="$(wget "$url.$hashtype" -t 3 -qO - | awk '{print $1}')"
		if [ -z "$checksum_remote" ]; then
			sfb_dbg "missing remote checksum for $filename, skipping redownload"
			return
		fi
		hashcmd=${hashtype%sum}sum
		checksum_local="$($hashcmd "$file" | awk '{print $1}')"
		if [ "$checksum_local" = "$checksum_remote" ]; then
			sfb_dbg "$hashcmd ok for $filename, skipping redownload"
			return
		fi
		sfb_warn "Local $hashcmd for $filename didn't match remote, redownloading..."
		rm "$file"
	elif [ -f "$file" ]; then
		fetch=0 # no need if already exists with no checksum to compare
	fi
	if [ $fetch -eq 1 ]; then
		sfb_dbg "downloading $url..."
		wget "$url" -t 3 --show-progress -qO "$file" || error=true
		if $error; then
			rm "$file" # remove residue 0 byte output file on dl errors
			$fail_on_error && sfb_error "Failed to download $url!"
		fi
	fi
}
sfb_ver() { echo "$*" | awk -F. '{ printf("%d%02d%02d%02d\n", $1,$2,$3,$4); }'; }
sfb_setup_hadk_env() {
	local env_file="$SFOSSDK_ROOT/home/$USER/.hadk.env" \
	      env="export SFB_ROOT=\"/parentroot$SFB_ROOT\"
export ANDROID_ROOT=\"/parentroot$ANDROID_ROOT\"
if [ \"\$MERSDKUBU\" ]; then
	SFB_ROOT=\"/parentroot\$SFB_ROOT\" ANDROID_ROOT=\"/parentroot\$ANDROID_ROOT\"
fi"
	env="$(echo "$env" | sed "s|/parentroot$SFB_ROOT/|\$SFB_ROOT/|")"
	sfb_write_if_different "$env" "$env_file"
}
sfb_chroot_check_suid() {
	local mnt="$(findmnt -nT "$PLATFORM_SDK_ROOT")" mntdir
	if echo "$mnt" | grep -q 'nosuid'; then
		mntdir="$(echo "$mnt" | awk '{print $1}')"
		sfb_error "PLATFORM_SDK_ROOT appears to be on a mount ($mntdir) with 'nosuid' option set!"
	fi
}
sfb_chroot_exists_sfossdk() { [ -f "$SFOSSDK_ROOT/bin/sh" ]; }
sfb_chroot_exists_habuild() { [ -f "$HABUILD_ROOT/bin/sh" ]; }
sfb_chroot_exists_sb2_target() { [ -f "$SB2_TARGET_ROOT/bin/sh" ]; }
sfb_chroot_exists_sb2_tooling() { [ -f "$SB2_TOOLING_ROOT/bin/sh" ]; }
sfb_chroot_sb2_setup() {
	local ans tooling tooling_url target target_url
	if sfb_array_contains "^\-(y|\-yes)$" "$@"; then
		ans="y"
	fi
	if sfb_chroot_exists_sb2_target; then
		sfb_prompt "Remove existing target chroot for $VENDOR-$DEVICE-$PORT_ARCH (y/N)?" ans "$SFB_YESNO_REGEX" "$ans"
		[[ "${ans^^}" != "Y"* ]] && return
		sfb_chroot sfossdk sh -c "sdk-assistant target remove -y $VENDOR-$DEVICE-$PORT_ARCH"
	fi
	tooling="Sailfish_OS-$TOOLING_RELEASE-Sailfish_SDK_Tooling-i486.tar.7z"
	tooling_url="$SFB_SDK_URL/targets/$tooling"
	target="Sailfish_OS-$TOOLING_RELEASE-Sailfish_SDK_Target-$PORT_ARCH.tar.7z"
	target_url="$SFB_SDK_URL/targets/$target"

	sfb_log "Fetching Sratchbox2 tooling & target chroot tarballs..."
	sfb_fetch -u "$tooling_url" -o "$SFB_ARC"/$tooling -c "md5sum"
	sfb_fetch -u "$target_url" -o "$SFB_ARC"/$target -c "md5sum"

	sfb_log "Setting up Scratchbox2 tooling & target $VENDOR-$DEVICE-$PORT_ARCH..."
	$SUDO rm -rf "$SB2_TARGET_ROOT"*
	if ! sfb_chroot_exists_sb2_tooling; then
		sfb_chroot sfossdk sh -c "sdk-assistant tooling create SailfishOS-$TOOLING_RELEASE /parentroot$SFB_ARC/$tooling --no-snapshot -y" || return 1
	fi
	sfb_chroot sfossdk sh -c "sdk-assistant target create $VENDOR-$DEVICE-$PORT_ARCH /parentroot$SFB_ARC/$target --tooling SailfishOS-$TOOLING_RELEASE --no-snapshot -y && sdk-assistant list" || return 1

	sfb_log "Running Scratchbox2 self-test for $VENDOR-$DEVICE-$PORT_ARCH..."
	sfb_chroot sfossdk sh -c 'cd;
cat > test.c <<EOF
#include <stdlib.h>
#include <stdio.h>
int main(void) {
printf("Hello, $PORT_ARCH!\n");
return EXIT_SUCCESS;
}
EOF
sb2 -t $VENDOR-$DEVICE-$PORT_ARCH gcc test.c -o test &&
sb2 -t $VENDOR-$DEVICE-$PORT_ARCH ./test;
ret=$?
rm test*;
exit $ret' || sfb_exit "${SFB_C_LRED}Failed!${SFB_C_RESET}"
	# && echo -e "${SFB_C_GREEN}Passed${SFB_C_RESET}"
}

sfb_chroot_setup_ubu() {
	local ans ubu_ver ubu_tarball ubu_tarball_url hostname repo_url
	if [ "$PORT_TYPE" != "hybris" ]; then
		sfb_log "Non-hybris port of type '$PORT_TYPE' doesn't require a HAL build chroot!"
		return
	fi
	if sfb_array_contains "^\-(y|\-yes)$" "$@"; then
		ans="y"
	fi
	if [ -d "$HABUILD_ROOT" ]; then
		sfb_prompt "Remove existing HAL build chroot (y/N)?" ans "$SFB_YESNO_REGEX" "$ans"
		[[ "${ans^^}" != "Y"* ]] && return
	fi

	if [ $ANDROID_MAJOR_VERSION -ge 7 ]; then
		ubu_ver="focal-20210531" # Ubuntu 20.04 (Java 8)
	else
		ubu_ver="trusty-20180613" # Ubuntu 14.04 (Java 7)
	fi
	ubu_tarball="ubuntu-$ubu_ver-android-rootfs.tar.bz2"
	ubu_tarball_url="http://releases.sailfishos.org/ubu/$ubu_tarball"

	sfb_log "Fetching HAL build (ubuntu-${ubu_ver%-*}) chroot tarball..."
	sfb_fetch -u "$ubu_tarball_url" -o "$SFB_ARC"/$ubu_tarball

	sfb_log "Setting up HAL build chroot, please wait..."
	$SUDO rm -rf "$HABUILD_ROOT"
	$SUDO mkdir -p "$HABUILD_ROOT"
	sfb_chroot_check_suid
	$SUDO tar xpf "$SFB_ARC"/$ubu_tarball -C "$HABUILD_ROOT" || return 1

	# setup proper env for non-interactive shell sessions
	$SUDO sed -i "$SFOSSDK_ROOT"/usr/bin/ubu-chroot \
		-e '/mer-ubusdk-bash-setup -c / s|fi;|fi; . ${HOMEDIR}/.mersdkubu.profile;|; /mer-ubusdk-bash-setup -c / s|bash -i|bash|'

	# avoid pointless warnings due to /var/run/dbus not being bind-mounted on sfossdk (anymore?)
	$SUDO awk -i inplace -v str='/var/run/dbus' 'index($0,str){$0="#"$0} 1' "$SFOSSDK_ROOT"/usr/bin/ubu-chroot

	if [ "$ubu_ver" = "focal-20210531" ]; then
		if [ $(sfb_ver $TOOLING_RELEASE) -lt $(sfb_ver 4.2) ] && ! grep -q 'bullseye' "$SFOSSDK_ROOT"/usr/bin/ubu-chroot; then
			# fix for "Unknown ubuntu version"
			$SUDO sed 's/jessie/bullseye/g' -i "$SFOSSDK_ROOT"/usr/bin/ubu-chroot
		fi
		# fix for "sudo: account validation failure, is your account locked?"
		echo "$USER:*:18779:0:99999:7:::" | $SUDO tee -a "$HABUILD_ROOT"/etc/shadow >/dev/null
	fi

	# silence "unable to resolve host" messages
	hostname="$(</etc/hostname)"
	$SUDO sed "s/\tlocalhost/\t$hostname/g" -i "$HABUILD_ROOT"/etc/hosts

	$SUDO mkdir -p "$HABUILD_ROOT"/home/$USER
	$SUDO chown -R $USER: "$HABUILD_ROOT"/home/$USER
	ln -s /parentroot/home/$USER/.mersdk.profile "$HABUILD_ROOT"/home/$USER/.mersdkubu.profile
	ln -s /parentroot/home/$USER/.hadk.env "$HABUILD_ROOT"/home/$USER/.hadk.env
	if [ -f "$SFOSSDK_ROOT/home/$USER/.gitconfig" ]; then
		ln -s /parentroot/home/$USER/.gitconfig "$HABUILD_ROOT"/home/$USER/.gitconfig
	fi

	# setup repo needed to sync hybris source tree
	repo_url="https://storage.googleapis.com/git-repo-downloads/repo"
	if [ "$ubu_ver" = "trusty-20180613" ]; then
		# fetch old Python 2.7 compatible Repo Launcher v1.x
		repo_url+="-1"
	fi
	sfb_chroot habuild "sudo curl -s $repo_url -o /usr/bin/repo && sudo chmod +x /usr/bin/repo" || return 1

	if [ "$ubu_ver" = "focal-20210531" ]; then
		# python2 is *still* used by various Android build scripts, additionally also
		# add missing cpio for initramfs generation
		sfb_chroot habuild 'sudo apt update && sudo apt install -y python cpio' || return 1
	fi
}
sfb_chroot_setup_sfossdk() {
	local extra_fetch_args=()
	if sfb_chroot_exists_sfossdk && [[ -d "$PLATFORM_SDK_ROOT/toolings" || -d "$PLATFORM_SDK_ROOT/targets" ]]; then
		sfb_log "Removing potentially existing sb2 targets & toolings..."
		sfb_chroot sfossdk sh -c 'for t in $(sdk-assistant target list); do sdk-assistant target remove -y $t; done'
		sfb_chroot sfossdk sh -c 'for t in $(sdk-assistant tooling list); do sdk-assistant tooling remove -y $t; done'
	fi

	sfb_log "Fetching SailfishOS SDK chroot tarball..."
	if [[ "$SDK_RELEASE" != "latest" && "$sdk_tarball_url" != *"/$SDK_RELEASE.deprecated/"* ]]; then
		extra_fetch_args+=(-F)
	fi
	if ! sfb_fetch -u "$sdk_tarball_url" -o "$SFB_ARC"/$sdk_tarball -c "md5" "${extra_fetch_args[@]}"; then
		# only tried when failed to download non-deprecated versioned SDK_RELEASE tarball
		sdk_tarball_url="${sdk_tarball_url/\/$SDK_RELEASE\//\/$SDK_RELEASE.deprecated\/}"
		sfb_fetch -u "$sdk_tarball_url" -o "$SFB_ARC"/$sdk_tarball -c "md5"
		sfb_warn "This port ($SFB_DEVICE) may be unmaintained; please update it or set SDK_RELEASE to '$SDK_RELEASE.deprecated'!"
	fi

	sfb_log "Setting up SailfishOS SDK chroot, please wait..."
	[ -f "$SFOSSDK_ROOT"/var/log/lastlog ] && $SUDO chattr -i "$SFOSSDK_ROOT"/var/log/lastlog
	$SUDO rm -rf "$SFOSSDK_ROOT"
	$SUDO mkdir -p "$PLATFORM_SDK_ROOT"/{targets,toolings,sdks/sfossdk}
	sfb_chroot_check_suid
	$SUDO tar xpf "$SFB_ARC"/$sdk_tarball -C "$SFOSSDK_ROOT" || return 1

	# setup proper env for non-interactive shell sessions
	sfb_update_sfossdk_chroot
	$SUDO sed -i "$SFOSSDK_CHROOT" \
		-e '/^sudo oneshot.*/a [ $# -gt 0 ] && . ${HOMEDIR}/.mersdk.profile' \
		-e '/echo "Mounting.*/ s|$| >/dev/null|' \
		-e '/echo "Entering chroot as .*/ s|$| >/dev/null|'

	# disable "Last login: ..." messages on chroot enter
	printf '' | $SUDO tee "$SFOSSDK_ROOT"/var/log/lastlog
	$SUDO chattr +i "$SFOSSDK_ROOT"/var/log/lastlog

	# silence the occasional "Did you know…?" motd messages
	echo '#!/bin/sh' | $SUDO tee "$SFOSSDK_ROOT"/usr/bin/sdk-motd >/dev/null

	$SUDO mkdir -p "$SFOSSDK_ROOT"/home/$USER
	$SUDO chown -R $USER: "$SFOSSDK_ROOT"/home/$USER
	cat << EOF > "$SFOSSDK_ROOT"/home/$USER/.mersdk.profile
export PATH=\$PATH:/sbin
. ~/.hadk.env
if [ -f "\$SFB_ROOT"/.lastdevice ]; then
	SFB_DEVICE="\$(<"\$SFB_ROOT"/.lastdevice)"
	. "\$SFB_ROOT/device/\$SFB_DEVICE/env.sh"
	croot() { cd "\$ANDROID_ROOT"; }
	if [ -z "\$MERSDKUBU" ]; then
		bp() { croot && rpm/dhd/helpers/build_packages.sh "\$@"; }
	fi
	croot
fi

# Stop here if not running interactively
[[ \$- != *i* ]] && return

alias clear="printf '\e[H\e[2J\e[3J'"
[ -d /etc/bash_completion.d ] && for i in /etc/bash_completion.d/*; do . \$i; done
complete -cf sudo

if [ -z "\$MERSDKUBU" ]; then
	PS1="PlatformSDK \\W \\\$ "
else
	PS1="HABUILD \\W \\\$ "
fi
if [ "\$SFB_DEVICE" ]; then
	echo "Env setup for \$SFB_DEVICE (\$PORT_ARCH) on SFOS \$RELEASE"
fi
EOF

	sfb_chroot sfossdk sh -c 'sudo zypper ref -f && \
sudo zypper --non-interactive in android-tools-hadk kmod' || return 1

	sfb_setup_hadk_env

	# reuse host ~/.gitconfig if found (needed by repo etc.)
	hostgitconf="$HOME/.gitconfig"
	if [ -f "$hostgitconf" ]; then
		sdkgitconf="$SFOSSDK_ROOT/home/$USER/.gitconfig"
		cp "$(readlink -f "$hostgitconf")" "$sdkgitconf"
		if grep -q 'signingkey' "$sdkgitconf"; then
			# drop signing key to avoid having to import it to the chroot(s)
			# (also dropping it significantly speeds up applying hybris-patches)
			sed '/signingkey/ s/^/#/' -i "$sdkgitconf"
		fi
	fi
}
sfb_chroot_setup() {
	local sdk_tarball sdk_tarball_url ans hostgitconf sdkgitconf
	if [ "$SDK_RELEASE" = "latest" ]; then
		sdk_tarball="Jolla-latest-SailfishOS_"
	else
		sdk_tarball="Sailfish_OS-Jolla_SDK-$TOOLING_RELEASE-"
	fi
	sdk_tarball+="Platform_SDK_Chroot-i486.tar.bz2"
	sdk_tarball_url="$SFB_SDK_URL/installers/$SDK_RELEASE/$sdk_tarball"
	if sfb_array_contains "^\-(y|\-yes)$" "$@"; then
		ans="y"
	fi
	if [ -d "$SFOSSDK_ROOT" ]; then
		sfb_prompt "Remove existing SailfishOS SDK chroot including sb2 toolings & targets (y/N)?" ans "$SFB_YESNO_REGEX" "$ans"
		if [[ "${ans^^}" = "Y"* ]]; then
			sfb_chroot_setup_sfossdk || return 1
		fi
	else
		sfb_chroot_setup_sfossdk || return 1
	fi

	sfb_chroot_sb2_setup "$@" || return 1

	if [ "$PORT_TYPE" = "hybris" ]; then
		sfb_chroot_setup_ubu "$@"
	fi
}

sfb_chroot() {
	local ret=0
	case "$1" in
		setup)
			shift
			sfb_hook_exec pre-chroot-setup
			sfb_chroot_setup "$@" || sfb_error "Failed to setup build chroot(s)!"
			sfb_hook_exec post-chroot-setup
			;;
		sfossdk)
			shift
			sfb_chroot_exists_sfossdk || sfb_error "Chroot for sfossdk isn't setup yet; check out '$0 chroot setup'!"
			sfb_setup_hadk_env
			sfb_hook_exec pre-chroot-enter sfossdk
			"$SFOSSDK_CHROOT" -m root "$@"; ret=$?
			sfb_hook_exec post-chroot-enter sfossdk
			;;
		habuild)
			shift
			sfb_chroot_exists_habuild || sfb_error "Chroot for habuild isn't setup yet; check out '$0 chroot setup'!"
			sfb_setup_hadk_env
			sfb_hook_exec pre-chroot-enter habuild
			sfb_chroot sfossdk ubu-chroot -r "/parentroot$HABUILD_ROOT" -m root "$@"; ret=$?
			sfb_hook_exec post-chroot-enter habuild
			;;
		*)
			sfb_usage chroot ;;
	esac
	return $ret
}
sfb_chroot_setup_usage() {
	sfb_usage_main+=(chroot "Interact with SailfishOS SDK & HAL build related chroots")
	sfb_usage_chroot=(
		setup "Setup the required chroots for building SFOS
           (and Android HAL for Hybris ports)"
		sfossdk "Enter/run commands in the SailfishOS platform SDK chroot"
		habuild "Enter/run commands Android HAL build chroot"
	)
	sfb_usage_chroot_setup_args=("-y|--yes" "Answer yes to remove existing build chroot questions automatically")
	sfb_usage_chroot_sfossdk_args=("" "[args to optionally pass directly to $(basename "$SFOSSDK_CHROOT") script]")
	sfb_usage_chroot_habuild_args=("" "[args to optionally pass directly to ubu-chroot script]")
}
