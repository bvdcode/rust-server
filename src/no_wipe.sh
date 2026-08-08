#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_RUST_ROOT="/steamcmd/rust"
readonly DEFAULT_OXIDE_RELEASE_API="https://api.github.com/repos/OxideMod/Oxide.Rust/releases/tags"
readonly DEFAULT_MIN_FREE_BYTES="1073741824"

TEMP_RELEASE_FILE=""
PARTIAL_BACKUP_PATH=""
BACKUP_ROOT_PATH=""
CURRENT_SAVE_PATH=""
CURRENT_SAVE_VERSION=""
COMPLETED_BACKUP_PATH=""
RUST_BUILD_ID=""
OXIDE_VERSION=""
OXIDE_PROTOCOL=""
declare -a MIGRATION_SOURCES=()
declare -a MIGRATION_TARGETS=()

log()
{
	printf 'No-wipe: %s\n' "$*"
}

fail()
{
	printf 'No-wipe preflight failed: %s\n' "$*" >&2
	return 1
}

cleanup()
{
	if [ -n "$TEMP_RELEASE_FILE" ] && [ -e "$TEMP_RELEASE_FILE" ]; then
		rm -f -- "$TEMP_RELEASE_FILE"
	fi

	if [ -n "$PARTIAL_BACKUP_PATH" ] && [ -d "$PARTIAL_BACKUP_PATH" ]; then
		case "$PARTIAL_BACKUP_PATH" in
		"$BACKUP_ROOT_PATH"/.*.partial)
			rm -rf -- "$PARTIAL_BACKUP_PATH"
			;;
		*)
			printf 'No-wipe cleanup refused unexpected path: %s\n' "$PARTIAL_BACKUP_PATH" >&2
			;;
		esac
	fi
}

trap cleanup EXIT

require_command()
{
	local command_name="$1"

	if ! command -v "$command_name" > /dev/null 2>&1; then
		fail "required command is unavailable: $command_name"
	fi
}

write_cache()
{
	local cache_path="$1"
	local cache_value="$2"
	local temporary_path="${cache_path}.tmp.$$"

	rm -f -- "$temporary_path"
	if ! printf '%s\n' "$cache_value" > "$temporary_path"; then
		rm -f -- "$temporary_path"
		fail "could not write cache file: $cache_path"
		return 1
	fi

	if ! mv -- "$temporary_path" "$cache_path"; then
		rm -f -- "$temporary_path"
		fail "could not publish cache file: $cache_path"
		return 1
	fi
}

extract_rust_save_version()
{
	local assembly_path="$1"
	local state_dir="$2"
	local assembly_hash
	local cache_path="$state_dir/rust-save-version.tsv"
	local cached_hash=""
	local cached_version=""
	local cached_extra=""
	local save_version

	assembly_hash="$(sha256sum -- "$assembly_path" | awk '{ print $1 }')"

	if [ -f "$cache_path" ]; then
		IFS=$'\t' read -r cached_hash cached_version cached_extra < "$cache_path" || true
		if [ "$cached_hash" = "$assembly_hash" ] &&
			[[ "$cached_version" =~ ^[1-9][0-9]*$ ]] &&
			[ -z "$cached_extra" ]; then
			printf '%s\n' "$cached_version"
			return 0
		fi
	fi

	if ! save_version="$(
		MONO_PATH="$(dirname -- "$assembly_path")" monodis "$assembly_path" 2> /dev/null |
		awk '
			BEGIN {
				in_method = 0
				candidate = ""
				method_version = ""
				method_matches = 0
				method_invalid = 0
				result = ""
			}
			/default string get_SaveFileName \(\)/ {
				in_method = 1
				candidate = ""
				method_version = ""
				method_matches = 0
				method_invalid = 0
				next
			}
			in_method && /ldc\.i4[ \t]+[0-9]+/ {
				candidate = $0
				sub(/^.*ldc\.i4[ \t]+/, "", candidate)
				sub(/[ \t].*$/, "", candidate)
				next
			}
			in_method && /ldstr "\.sav"/ {
				if (candidate != "") {
					if (method_matches == 0) {
						method_version = candidate
					} else if (method_version != candidate) {
						method_invalid = 1
					}
					method_matches++
					candidate = ""
				}
				next
			}
			in_method && /end of method/ {
				if ($0 ~ /World::get_SaveFileName/ && method_matches > 0 && method_invalid == 0) {
					result = method_version
				}
				in_method = 0
			}
			END {
				if (result ~ /^[1-9][0-9]*$/) {
					print result
				} else {
					exit 1
				}
			}
		'
	)"; then
		fail "could not extract World.SaveFileName version from $assembly_path"
		return 1
	fi

	if ! [[ "$save_version" =~ ^[1-9][0-9]*$ ]]; then
		fail "Rust save version is invalid: $save_version"
		return 1
	fi

	write_cache "$cache_path" "${assembly_hash}"$'\t'"${save_version}"
	printf '%s\n' "$save_version"
}

extract_oxide_release()
{
	local oxide_path="$1"
	local state_dir="$2"
	local release_api="$3"
	local oxide_hash
	local cache_path="$state_dir/oxide-protocol.tsv"
	local cached_hash=""
	local cached_version=""
	local cached_protocol=""
	local cached_save_version=""
	local cached_extra=""
	local assembly_version
	local oxide_version
	local release_values
	local protocol
	local save_version

	oxide_hash="$(sha256sum -- "$oxide_path" | awk '{ print $1 }')"

	if [ -f "$cache_path" ]; then
		IFS=$'\t' read -r cached_hash cached_version cached_protocol cached_save_version cached_extra < "$cache_path" || true
		if [ "$cached_hash" = "$oxide_hash" ] &&
			[[ "$cached_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
			[[ "$cached_protocol" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
			[[ "$cached_save_version" =~ ^[1-9][0-9]*$ ]] &&
			[ -z "$cached_extra" ]; then
			printf '%s\t%s\t%s\n' "$cached_version" "$cached_protocol" "$cached_save_version"
			return 0
		fi
	fi

	if ! assembly_version="$(monodis --assembly "$oxide_path" 2> /dev/null | awk '$1 == "Version:" && version == "" { version = $2 } END { if (version != "") print version; else exit 1 }')"; then
		fail "could not inspect Oxide assembly version: $oxide_path"
		return 1
	fi

	oxide_version="${assembly_version%.0}"
	if ! [[ "$oxide_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		fail "Oxide assembly version is invalid: $assembly_version"
		return 1
	fi

	if ! TEMP_RELEASE_FILE="$(mktemp "$state_dir/oxide-release.XXXXXX.json")"; then
		fail "could not create a temporary Oxide release metadata file"
		return 1
	fi
	if ! curl \
		--fail \
		--location \
		--silent \
		--show-error \
		--header "Accept: application/vnd.github+json" \
		--header "User-Agent: bvdcode-rust-server" \
		--output "$TEMP_RELEASE_FILE" \
		"${release_api%/}/${oxide_version}"; then
		fail "could not fetch official Oxide release metadata for $oxide_version"
		return 1
	fi

	if ! release_values="$(EXPECTED_OXIDE_VERSION="$oxide_version" node - "$TEMP_RELEASE_FILE" <<'NODE'
const fs = require("fs");

const filePath = process.argv[2];
const expectedVersion = process.env.EXPECTED_OXIDE_VERSION;
const release = JSON.parse(fs.readFileSync(filePath, "utf8"));

if (release.tag_name !== expectedVersion || typeof release.body !== "string") {
    process.exit(1);
}

const matches = [...release.body.matchAll(/\(([0-9]+)\.([0-9]+)\.([0-9]+)\)/g)];
const protocols = new Map();

for (const match of matches) {
    protocols.set(match[0], {
        protocol: `${match[1]}.${match[2]}.${match[3]}`,
        saveVersion: match[2],
    });
}

if (protocols.size !== 1) {
    process.exit(1);
}

const value = protocols.values().next().value;
process.stdout.write(`${value.protocol}\t${value.saveVersion}\n`);
NODE
	)"; then
		fail "Oxide release $oxide_version does not contain one unambiguous Rust protocol"
		return 1
	fi

	rm -f -- "$TEMP_RELEASE_FILE"
	TEMP_RELEASE_FILE=""

	IFS=$'\t' read -r protocol save_version cached_extra <<< "$release_values"
	if ! [[ "$protocol" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
		! [[ "$save_version" =~ ^[1-9][0-9]*$ ]] ||
		[ -n "$cached_extra" ]; then
		fail "Oxide release protocol metadata is invalid: $release_values"
		return 1
	fi

	write_cache "$cache_path" "${oxide_hash}"$'\t'"${oxide_version}"$'\t'"${protocol}"$'\t'"${save_version}"
	printf '%s\t%s\t%s\n' "$oxide_version" "$protocol" "$save_version"
}

validate_paths()
{
	local rust_root="$1"
	local server_root="$2"
	local identity_path="$3"
	local backup_root="$4"

	if [ "$(realpath -m -- "$rust_root")" = "/" ]; then
		fail "RUST_ROOT cannot be the filesystem root"
		return 1
	fi

	if [ "$backup_root" = "/" ]; then
		fail "backup directory cannot be the filesystem root"
		return 1
	fi

	case "$identity_path" in
		"$server_root"/*)
			;;
		*)
			fail "server identity resolves outside the server directory: $identity_path"
			return 1
			;;
	esac

	case "$backup_root" in
		"$server_root"|"$server_root"/*)
			fail "backup directory must be outside $server_root"
			return 1
			;;
	esac
}

rollback_migration()
{
	local server_root="$1"
	local completed_backup_path="$2"
	local renamed_count="$3"
	local rollback_index
	local source_path
	local target_path
	local relative_path
	local rollback_failed="0"

	for ((rollback_index = renamed_count - 1; rollback_index >= 0; rollback_index--)); do
		source_path="${MIGRATION_SOURCES[$rollback_index]}"
		target_path="${MIGRATION_TARGETS[$rollback_index]}"

		if [ -e "$source_path" ] || [ -L "$source_path" ] || [ ! -f "$target_path" ]; then
			rollback_failed="1"
			continue
		fi

		if ! mv -T --no-clobber -- "$target_path" "$source_path" ||
			[ -e "$target_path" ] || [ ! -f "$source_path" ]; then
			rollback_failed="1"
			continue
		fi

		relative_path="${source_path#"$server_root"/}"
		if ! cmp --silent -- "$source_path" "$completed_backup_path/server/$relative_path"; then
			rollback_failed="1"
		fi
	done

	[ "$rollback_failed" = "0" ]
}

find_current_save()
{
	local identity_path="$1"
	local save_path
	local save_name
	local -a save_paths=()

	while IFS= read -r -d '' save_path; do
		save_paths+=("$save_path")
	done < <(find "$identity_path" -maxdepth 1 -type f -name '*.sav' -print0 | sort -z)

	if [ "${#save_paths[@]}" -eq 0 ]; then
		CURRENT_SAVE_PATH=""
		CURRENT_SAVE_VERSION=""
		return 0
	fi

	if [ "${#save_paths[@]}" -ne 1 ]; then
		fail "expected exactly one primary .sav in $identity_path, found ${#save_paths[@]}"
		return 1
	fi

	save_path="${save_paths[0]}"
	save_name="$(basename -- "$save_path")"
	if ! [[ "$save_name" =~ \.([1-9][0-9]*)\.sav$ ]]; then
		fail "could not determine save version from $save_name"
		return 1
	fi

	CURRENT_SAVE_PATH="$save_path"
	CURRENT_SAVE_VERSION="${BASH_REMATCH[1]}"
}

build_migration_plan()
{
	local identity_path="$1"
	local current_version="$2"
	local target_version="$3"
	local source_path
	local source_name
	local target_name
	local target_path
	local primary_found="0"
	local -A planned_targets=()

	MIGRATION_SOURCES=()
	MIGRATION_TARGETS=()

	while IFS= read -r -d '' source_path; do
		source_name="$(basename -- "$source_path")"
		target_name="${source_name//.${current_version}./.${target_version}.}"
		target_path="$identity_path/$target_name"

		if [ "$source_name" = "$target_name" ]; then
			fail "could not build target name for $source_name"
			return 1
		fi

		if [ -e "$target_path" ] || [ -L "$target_path" ]; then
			fail "migration target already exists: $target_path"
			return 1
		fi

		if [ -n "${planned_targets[$target_path]+configured}" ]; then
			fail "multiple source files map to the same migration target: $target_path"
			return 1
		fi
		planned_targets["$target_path"]="configured"

		if [ "$source_path" = "$CURRENT_SAVE_PATH" ]; then
			primary_found="1"
		fi

		MIGRATION_SOURCES+=("$source_path")
		MIGRATION_TARGETS+=("$target_path")
	done < <(find "$identity_path" -maxdepth 1 -type f -name "*.${current_version}.*" -print0 | sort -z)

	if [ "${#MIGRATION_SOURCES[@]}" -eq 0 ] || [ "$primary_found" != "1" ]; then
		fail "migration plan does not contain the primary save"
		return 1
	fi
}

create_server_backup()
{
	local server_root="$1"
	local backup_root="$2"
	local current_version="$3"
	local target_version="$4"
	local min_free_bytes="$5"
	local timestamp
	local backup_name
	local completed_backup_path
	local source_bytes
	local available_bytes
	local source_entries
	local backup_entries
	local relative_path
	local source_path
	local source_hash
	local index
	local manifest_path

	mkdir -p -- "$backup_root"

	source_bytes="$(du -s -B1 -- "$server_root" | awk '{ print $1 }')"
	available_bytes="$(df -P -B1 -- "$backup_root" | awk 'NR == 2 { print $4 }')"

	if ! [[ "$source_bytes" =~ ^[0-9]+$ ]] || ! [[ "$available_bytes" =~ ^[0-9]+$ ]]; then
		fail "could not determine backup space requirements"
		return 1
	fi

	if (( available_bytes < source_bytes + min_free_bytes )); then
		fail "insufficient backup space: need $((source_bytes + min_free_bytes)) bytes, have $available_bytes bytes"
		return 1
	fi

	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	backup_name="${timestamp}-${current_version}-to-${target_version}-$$"
	completed_backup_path="$backup_root/$backup_name"
	PARTIAL_BACKUP_PATH="$backup_root/.${backup_name}.partial"

	if [ -e "$completed_backup_path" ] || [ -e "$PARTIAL_BACKUP_PATH" ]; then
		fail "backup path already exists for this migration"
		return 1
	fi

	mkdir -- "$PARTIAL_BACKUP_PATH"
	if ! cp -a --reflink=auto -- "$server_root" "$PARTIAL_BACKUP_PATH/server"; then
		fail "could not copy the complete server directory"
		return 1
	fi

	source_entries="$(find "$server_root" -mindepth 1 -printf '.' | wc -c)"
	backup_entries="$(find "$PARTIAL_BACKUP_PATH/server" -mindepth 1 -printf '.' | wc -c)"
	if [ "$source_entries" != "$backup_entries" ]; then
		fail "backup inventory mismatch: source=$source_entries backup=$backup_entries"
		return 1
	fi

	if ! diff --brief --recursive --no-dereference -- "$server_root" "$PARTIAL_BACKUP_PATH/server" > /dev/null; then
		fail "complete server backup verification failed"
		return 1
	fi

	for index in "${!MIGRATION_SOURCES[@]}"; do
		source_path="${MIGRATION_SOURCES[$index]}"
		relative_path="${source_path#"$server_root"/}"
		if ! cmp --silent -- "$source_path" "$PARTIAL_BACKUP_PATH/server/$relative_path"; then
			fail "backup verification failed for $relative_path"
			return 1
		fi
	done

	manifest_path="$PARTIAL_BACKUP_PATH/manifest.txt"
	{
		printf 'created_at=%s\n' "$timestamp"
		printf 'identity=%s\n' "$RUST_SERVER_IDENTITY"
		printf 'rust_save_version_from=%s\n' "$current_version"
		printf 'rust_save_version_to=%s\n' "$target_version"
		printf 'rust_build_id=%s\n' "$RUST_BUILD_ID"
		printf 'oxide_version=%s\n' "$OXIDE_VERSION"
		printf 'oxide_protocol=%s\n' "$OXIDE_PROTOCOL"
		printf 'server_entries=%s\n' "$source_entries"
		printf 'versioned_files=%s\n' "${#MIGRATION_SOURCES[@]}"
		for source_path in "${MIGRATION_SOURCES[@]}"; do
			relative_path="${source_path#"$server_root"/}"
			source_hash="$(sha256sum -- "$source_path" | awk '{ print $1 }')"
			printf 'sha256=%s  server/%s\n' "$source_hash" "$relative_path"
		done
	} > "$manifest_path"

	if ! mv -- "$PARTIAL_BACKUP_PATH" "$completed_backup_path"; then
		fail "could not publish completed backup"
		return 1
	fi

	PARTIAL_BACKUP_PATH=""
	COMPLETED_BACKUP_PATH="$completed_backup_path"
	log "complete server backup created at $COMPLETED_BACKUP_PATH"
}

migrate_versioned_files()
{
	local server_root="$1"
	local completed_backup_path="$2"
	local index
	local source_path
	local target_path
	local relative_path
	local renamed_count="0"
	local verification_failed="0"

	for index in "${!MIGRATION_SOURCES[@]}"; do
		source_path="${MIGRATION_SOURCES[$index]}"
		target_path="${MIGRATION_TARGETS[$index]}"

		if mv -T --no-clobber -- "$source_path" "$target_path" &&
			[ ! -e "$source_path" ] && [ -f "$target_path" ]; then
			renamed_count=$((renamed_count + 1))
			continue
		fi

		if [ ! -e "$source_path" ] && [ -f "$target_path" ]; then
			renamed_count=$((renamed_count + 1))
		fi

		if ! rollback_migration "$server_root" "$completed_backup_path" "$renamed_count"; then
			fail "rename failed and rollback was incomplete; restore from $completed_backup_path"
			return 1
		fi

		fail "rename failed; completed changes were rolled back"
		return 1
	done

	for index in "${!MIGRATION_TARGETS[@]}"; do
		source_path="${MIGRATION_SOURCES[$index]}"
		target_path="${MIGRATION_TARGETS[$index]}"
		relative_path="${source_path#"$server_root"/}"

		if [ -e "$source_path" ] || [ ! -f "$target_path" ]; then
			verification_failed="1"
			break
		fi

		if ! cmp --silent -- "$target_path" "$completed_backup_path/server/$relative_path"; then
			verification_failed="1"
			break
		fi
	done

	if [ "$verification_failed" = "1" ]; then
		if ! rollback_migration "$server_root" "$completed_backup_path" "$renamed_count"; then
			fail "post-migration verification failed and rollback was incomplete; restore from $completed_backup_path"
			return 1
		fi

		fail "post-migration verification failed; changes were rolled back"
		return 1
	fi

	sync -f -- "$(dirname -- "${MIGRATION_TARGETS[0]}")"
	log "renamed ${#MIGRATION_TARGETS[@]} files without changing their contents"
}

read_rust_build_id()
{
	local manifest_path="$1"
	local build_id="unknown"

	if [ -f "$manifest_path" ]; then
		build_id="$(awk -F '"' '{ for (field_index = 2; field_index <= NF; field_index += 2) if ($field_index == "buildid" && field_index + 2 <= NF) build_id = $(field_index + 2) } END { if (build_id != "") print build_id }' "$manifest_path")"
	fi

	if ! [[ "$build_id" =~ ^[0-9]+$ ]]; then
		build_id="unknown"
	fi

	printf '%s\n' "$build_id"
}

main()
{
	local enabled="${RUST_NO_WIPE_ENABLED:-0}"
	local rust_root
	local server_root
	local identity_path
	local backup_root
	local state_dir
	local assembly_path
	local oxide_path
	local release_api="${RUST_NO_WIPE_OXIDE_RELEASE_API:-$DEFAULT_OXIDE_RELEASE_API}"
	local min_free_bytes="${RUST_NO_WIPE_MIN_FREE_BYTES:-$DEFAULT_MIN_FREE_BYTES}"
	local rust_save_version
	local oxide_values
	local oxide_save_version
	local oxide_extra=""
	local command_name

	case "$enabled" in
		0|false)
			log "disabled"
			return 0
			;;
		1|true)
			;;
		*)
			fail "RUST_NO_WIPE_ENABLED must be 0, 1, false, or true"
			return 1
			;;
	esac

	if [ "${RUST_OXIDE_ENABLED:-0}" != "1" ]; then
		fail "RUST_NO_WIPE_ENABLED requires RUST_OXIDE_ENABLED=1"
		return 1
	fi

	if [ -z "${RUST_SERVER_IDENTITY:-}" ] ||
		[[ "$RUST_SERVER_IDENTITY" == */* ]] ||
		[[ "$RUST_SERVER_IDENTITY" == *\\* ]] ||
		[ "$RUST_SERVER_IDENTITY" = "." ] ||
		[ "$RUST_SERVER_IDENTITY" = ".." ]; then
		fail "RUST_SERVER_IDENTITY is invalid"
		return 1
	fi

	if ! [[ "$min_free_bytes" =~ ^[0-9]{1,18}$ ]]; then
		fail "RUST_NO_WIPE_MIN_FREE_BYTES must be a non-negative integer of at most 18 digits"
		return 1
	fi
	min_free_bytes=$((10#$min_free_bytes))

	for command_name in awk basename cmp cp curl date df diff dirname du find flock mkdir mktemp monodis mv node realpath rm sha256sum sort sync wc; do
		require_command "$command_name"
	done

	rust_root="$(realpath -m -- "${RUST_ROOT:-$DEFAULT_RUST_ROOT}")"
	server_root="$(realpath -m -- "$rust_root/server")"
	identity_path="$(realpath -m -- "$server_root/$RUST_SERVER_IDENTITY")"
	backup_root="$(realpath -m -- "${RUST_NO_WIPE_BACKUP_DIR:-$rust_root/server-backups}")"
	BACKUP_ROOT_PATH="$backup_root"
	state_dir="$rust_root/.no-wipe"
	assembly_path="$rust_root/RustDedicated_Data/Managed/Assembly-CSharp.dll"
	oxide_path="$rust_root/RustDedicated_Data/Managed/Oxide.Rust.dll"

	validate_paths "$rust_root" "$server_root" "$identity_path" "$backup_root"

	if [ ! -d "$identity_path" ]; then
		fail "server identity directory does not exist: $identity_path"
		return 1
	fi

	if [ ! -f "$assembly_path" ] || [ ! -f "$oxide_path" ]; then
		fail "Rust or Oxide assemblies are missing"
		return 1
	fi

	mkdir -p -- "$state_dir"
	if ! exec 9> "$state_dir/preflight.lock"; then
		fail "could not open the preflight lock"
		return 1
	fi
	if ! flock --nonblock 9; then
		fail "another no-wipe preflight is already running"
		return 1
	fi

	rust_save_version="$(extract_rust_save_version "$assembly_path" "$state_dir")"
	oxide_values="$(extract_oxide_release "$oxide_path" "$state_dir" "$release_api")"
	IFS=$'\t' read -r OXIDE_VERSION OXIDE_PROTOCOL oxide_save_version oxide_extra <<< "$oxide_values"

	if [ -n "$oxide_extra" ] || ! [[ "$oxide_save_version" =~ ^[1-9][0-9]*$ ]]; then
		fail "could not read verified Oxide protocol metadata"
		return 1
	fi

	if [ "$rust_save_version" != "$oxide_save_version" ]; then
		fail "installed Rust expects save version $rust_save_version, but Oxide $OXIDE_VERSION targets $OXIDE_PROTOCOL"
		return 1
	fi

	RUST_BUILD_ID="$(read_rust_build_id "$rust_root/steamapps/appmanifest_258550.acf")"
	log "verified Rust build $RUST_BUILD_ID save version $rust_save_version against Oxide $OXIDE_VERSION ($OXIDE_PROTOCOL)"

	find_current_save "$identity_path"
	if [ -z "$CURRENT_SAVE_PATH" ]; then
		log "no existing primary save found; no migration is required"
		return 0
	fi

	if [ "$CURRENT_SAVE_VERSION" = "$rust_save_version" ]; then
		log "save version $CURRENT_SAVE_VERSION is already current"
		return 0
	fi

	if (( CURRENT_SAVE_VERSION > rust_save_version )); then
		fail "save downgrade is not allowed: $CURRENT_SAVE_VERSION -> $rust_save_version"
		return 1
	fi

	log "preparing save migration $CURRENT_SAVE_VERSION -> $rust_save_version"
	build_migration_plan "$identity_path" "$CURRENT_SAVE_VERSION" "$rust_save_version"
	create_server_backup "$server_root" "$backup_root" "$CURRENT_SAVE_VERSION" "$rust_save_version" "$min_free_bytes"
	migrate_versioned_files "$server_root" "$COMPLETED_BACKUP_PATH"
	log "save migration $CURRENT_SAVE_VERSION -> $rust_save_version completed"
}

main "$@"
