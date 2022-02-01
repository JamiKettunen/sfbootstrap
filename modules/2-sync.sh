module_name=sync

sfb_local_repo_state() {
	local dir="${1:-$PWD}" branch origin common_base local_ref remote_ref
	if [ "$(git -C "$dir" status -s 2>/dev/null)" ]; then
		echo "dirty"; return
	fi
	branch="${2:-$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)}"
	origin="${3:-origin}/$branch"
	common_base=$(git -C "$dir" merge-base $branch $origin 2>/dev/null)
	local_ref=$(git -C "$dir" rev-parse $branch 2>/dev/null)
	remote_ref=$(git -C "$dir" rev-parse $origin 2>/dev/null)
	if [[ -z "$common_base" || -z "$local_ref" || -z "$remote_ref" ]]; then
		echo "unknown"; return
	fi
	if [ "$local_ref" = "$remote_ref" ]; then
		echo "up-to-date"
	elif [ "$local_ref" = "$common_base" ]; then
		echo "behind"
	elif [ "$remote_ref" = "$common_base" ]; then
		echo "ahead"
	else
		echo "diverged"
	fi
}
sfb_git_clone_or_pull() {
	local arg url dir origin branch shallow=0 dir_local cmd=(git) state commits
	for arg in "$@"; do
		case "$1" in
			-u) url="$2"; shift ;;
			-d) dir="$2"; shift ;;
			-o) origin=$2; shift ;;
			-b) branch=$2; shift ;;
			-s) shallow=$2; shift ;;
		esac
		shift
	done
	if [ -z "$dir" ]; then
		sfb_error "A specified directory is required to clone or update a local repo!"
	fi
	dir_local="${dir#"$ANDROID_ROOT/"}"
	[[ "$dir_local" = "$HOME"* ]] && dir_local="~${dir_local#"$HOME"}"

	if [ -d "$dir" ]; then
		cmd+=(-C "$dir")
		sfb_dbg "updating $url clone @ $dir_local (shallow: $shallow)..."
		if [ $shallow -eq 0 ]; then
			"${cmd[@]}" pull --recurse-submodules && return
		else
			"${cmd[@]}" fetch --recurse-submodules --depth 1
		fi

		state="$(sfb_local_repo_state "$dir" "$branch" "$origin")"
		case "$state" in
			up-to-date) return ;; # no need to update
			behind) : ;; # update out-of-date repo
			diverged)
				commits=$("${cmd[@]}" rev-list --count HEAD) # 1 on shallow clones
				if [ $commits -gt 1 ]; then
					sfb_error "Refusing to update diverged local repo with >1 commit!"
				fi
				;;
			*) sfb_error "Refusing to update '$dir_local' in a state of '$state'!" ;;
		esac
		cmd+=(reset --hard $origin --recurse-submodules)
	else
		if [ -z "$url" ]; then
			sfb_error "Cannot create a local repo clone without a URL!"
		fi
		cmd+=(clone --recurse-submodules)
		if [ "$branch" ]; then
			cmd+=(-b $branch)
		fi
		if [ $shallow -eq 1 ]; then
			cmd+=(--depth 1)
		fi
		cmd+=("$url" "$dir")
	fi
	"${cmd[@]}" || sfb_error "Failed to create a local clone of $url!"
}

sfb_sync_hybris_repos() {
	local ans extra_init_args="" branch="hybris-$HYBRIS_VER"
	if sfb_array_contains "^\-(y|\-yes)$" "$@"; then
		ans="y"
	fi
	if sfb_array_contains "^\-(s|\-shallow)$" "$@"; then
		extra_init_args+=" --depth 1"
	fi

	if [ ! -d "$ANDROID_ROOT/.repo" ]; then
		#sfb_hook_exec pre-repo-init
		sfb_log "Initializing new $branch source tree..."
		sfb_chroot habuild "repo init -u $REPO_INIT_URL -b $branch --platform=linux$extra_init_args" || return 1
		if [ "$REPO_LOCAL_MANIFESTS_URL" ]; then
			git clone -b $branch "$REPO_LOCAL_MANIFESTS_URL" "$ANDROID_ROOT/.repo/local_manifests" || return 1
		fi
		#sfb_hook_exec post-repo-init
	fi

	if sfb_manual_hybris_patches_applied; then
		sfb_prompt "Applied hybris-patches detected; run 'repo sync -l' & discard ALL local changes (y/N)?" ans "$SFB_YESNO_REGEX" "$ans"
		[[ "${ans^^}" != "Y"* ]] && return
		sfb_chroot habuild "repo sync -l" || return 1
	fi

	#sfb_hook_exec pre-repo-sync
	if [ -d "$ANDROID_ROOT/.repo/local_manifests/.git" ]; then
		sfb_log "Syncing local manifests..."
		git -C "$ANDROID_ROOT/.repo/local_manifests" pull || return 1
	fi
	sfb_log "Syncing $branch source tree with $SFB_JOBS jobs..."
	sfb_chroot habuild "repo sync -c -j$SFB_JOBS --fail-fast --fetch-submodules --no-clone-bundle --no-tags" || return 1
	#sfb_hook_exec post-repo-sync
}
sfb_sync_extra_repos() {
	local clone_only=0 i dir_local url dir branch is_shallow extra_args
	if [ ${#REPOS[@]} -eq 0 ]; then
		return # no need to setup any extra repos
	fi
	if sfb_array_contains "^\-(c|\-clone-only)$" "$@"; then
		clone_only=1
	fi
	# repo parts => 0:url 1:dir 2:branch 3:is_shallow
	for i in $(seq 0 4 $((${#REPOS[@]}-1))); do
		dir_local="${REPOS[$(($i+1))]}"
		url="${REPOS[$i]}" dir="$ANDROID_ROOT/$dir_local" branch="${REPOS[$(($i+2))]}" is_shallow=${REPOS[$(($i+3))]} extra_args=()
		#sfb_hook_exec pre-repo-sync "$dir"
		if [ -d "$dir" ]; then
			if [ $clone_only -eq 1 ]; then
				continue # avoid repo updates in clone-only mode
			fi
			sfb_log "Updating extra repo $dir_local..."
		else
			sfb_log "Cloning extra repo $dir_local..."
		fi
		if [ "$branch" ]; then
			extra_args+=(-b $branch)
		fi
		sfb_git_clone_or_pull -u "$url" -d "$dir" -s $is_shallow "${extra_args[@]}"
		#sfb_hook_exec post-repo-sync "$dir"
	done
}

sfb_sync() {
	if [ "$PORT_TYPE" = "hybris" ]; then
		sfb_sync_hybris_repos "$@"
	fi
	sfb_sync_extra_repos "$@"
}
sfb_sync_setup_usage() {
	sfb_usage_main+=(sync "Synchronize repos for device")
	sfb_usage_main_sync_args=(
		"-y|--yes" "Answer yes to 'repo sync -l' question automatically on hybris ports"
		"-s|--shallow" "Initialize manifest repos as shallow clones on hybris ports"
		"-c|--clone-only" "Don't attempt to update pre-existing extra repos"
	)
}
