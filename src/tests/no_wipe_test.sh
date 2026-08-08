#!/usr/bin/env bash

set -Eeuo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NO_WIPE_SCRIPT="$(realpath "$TESTS_DIR/../no_wipe.sh")"
readonly TESTS_DIR
readonly NO_WIPE_SCRIPT

TEST_ROOT="$(mktemp -d)"
PASSED_TESTS=0

cleanup()
{
	case "$TEST_ROOT" in
		/tmp/*)
			rm -rf -- "$TEST_ROOT"
			;;
		*)
			printf 'Refusing to remove unexpected test path: %s\n' "$TEST_ROOT" >&2
			;;
	esac
}

trap cleanup EXIT

pass()
{
	PASSED_TESTS=$((PASSED_TESTS + 1))
	printf 'PASS: %s\n' "$1"
}

fail_test()
{
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

assert_exists()
{
	[ -e "$1" ] || fail_test "expected path to exist: $1"
}

assert_not_exists()
{
	[ ! -e "$1" ] || fail_test "expected path to be absent: $1"
}

assert_content()
{
	local expected="$1"
	local path="$2"
	local actual

	actual="$(cat -- "$path")"
	[ "$actual" = "$expected" ] || fail_test "unexpected content in $path"
}

assert_contains()
{
	local expected="$1"
	local path="$2"

	grep -Fq -- "$expected" "$path" || fail_test "expected '$expected' in $path"
}

assert_no_completed_backup()
{
	local backup_root="$1"

	if [ -d "$backup_root" ] && find "$backup_root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | grep -q .; then
		fail_test "unexpected completed backup in $backup_root"
	fi
}

assert_no_backup_artifacts()
{
	local backup_root="$1"

	if [ -d "$backup_root" ] && find "$backup_root" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
		fail_test "unexpected backup artifact in $backup_root"
	fi
}

setup_case()
{
	local case_name="$1"

	CASE_ROOT="$TEST_ROOT/$case_name"
	RUST_ROOT_PATH="$CASE_ROOT/rust"
	IDENTITY_PATH="$RUST_ROOT_PATH/server/main"
	SIBLING_IDENTITY_PATH="$RUST_ROOT_PATH/server/sibling"
	FAKE_BIN_PATH="$CASE_ROOT/bin"
	BACKUP_ROOT_PATH="$RUST_ROOT_PATH/server-backups"

	mkdir -p \
		"$RUST_ROOT_PATH/RustDedicated_Data/Managed" \
		"$RUST_ROOT_PATH/steamapps" \
		"$IDENTITY_PATH/cfg" \
		"$SIBLING_IDENTITY_PATH" \
		"$FAKE_BIN_PATH"

	printf 'rust-assembly-%s\n' "$case_name" > "$RUST_ROOT_PATH/RustDedicated_Data/Managed/Assembly-CSharp.dll"
	printf 'oxide-assembly-%s\n' "$case_name" > "$RUST_ROOT_PATH/RustDedicated_Data/Managed/Oxide.Rust.dll"
	printf '"AppState" { "buildid" "24587531" }\n' > "$RUST_ROOT_PATH/steamapps/appmanifest_258550.acf"

	cat > "$FAKE_BIN_PATH/monodis" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${1:-}" = "--assembly" ]; then
	printf 'Assembly Table\n'
	printf 'Version: %s.0\n' "${FAKE_OXIDE_VERSION:?}"
	exit 0
fi

readonly second_version="${FAKE_SECOND_RUST_SAVE_VERSION:-${FAKE_RUST_SAVE_VERSION:?}}"
cat <<IL
.method public static hidebysig specialname
       default string get_SaveFileName () cil managed noinlining
{
    IL_001e: ldc.i4 ${FAKE_RUST_SAVE_VERSION}
    IL_0023: stloc.0
    IL_002b: ldstr ".sav"
    IL_0092: ldc.i4 ${second_version}
    IL_0097: stloc.0
    IL_00a2: ldstr ".sav"
} // end of method World::get_SaveFileName
IL
SCRIPT

	cat > "$FAKE_BIN_PATH/curl" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

output_path=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--output)
			output_path="$2"
			shift 2
			;;
		*)
			shift
			;;
	esac
done

[ -n "$output_path" ]
printf '{"tag_name":"%s","body":"Patch for Rust (%s)"}\n' \
	"${FAKE_OXIDE_VERSION:?}" \
	"${FAKE_OXIDE_PROTOCOL:?}" > "$output_path"
SCRIPT

	chmod +x "$FAKE_BIN_PATH/monodis" "$FAKE_BIN_PATH/curl"
}

run_no_wipe()
{
	env \
		PATH="$FAKE_BIN_PATH:$PATH" \
		RUST_ROOT="$RUST_ROOT_PATH" \
		RUST_SERVER_IDENTITY="main" \
		RUST_OXIDE_ENABLED="1" \
		RUST_NO_WIPE_ENABLED="1" \
		RUST_NO_WIPE_MIN_FREE_BYTES="0" \
		FAKE_RUST_SAVE_VERSION="${FAKE_RUST_SAVE_VERSION:-283}" \
		FAKE_OXIDE_VERSION="${FAKE_OXIDE_VERSION:-2.0.1000}" \
		FAKE_OXIDE_PROTOCOL="${FAKE_OXIDE_PROTOCOL:-2630.283.1}" \
		"$@" \
		bash "$NO_WIPE_SCRIPT"
}

find_completed_backup()
{
	find "$BACKUP_ROOT_PATH" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print -quit
}

test_disabled_mode()
{
	RUST_NO_WIPE_ENABLED=0 bash "$NO_WIPE_SCRIPT" > /dev/null
	pass "disabled mode has no runtime dependencies"
}

test_first_start_without_save()
{
	setup_case "first-start"
	run_no_wipe > /dev/null
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "first start without a save does not create a backup"
}

test_current_save_version()
{
	setup_case "current"
	printf 'world-current\n' > "$IDENTITY_PATH/amazon.283.sav"
	run_no_wipe > /dev/null
	assert_exists "$IDENTITY_PATH/amazon.283.sav"
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "current save version is left unchanged"
}

test_successful_migration()
{
	local completed_backup

	setup_case "migration"
	printf 'world-main\n' > "$IDENTITY_PATH/amazon.282.sav"
	printf 'world-backup\n' > "$IDENTITY_PATH/amazon.282.sav.1"
	printf 'clans\n' > "$IDENTITY_PATH/clans.282.db"
	printf 'wal\n' > "$IDENTITY_PATH/clans.282.db-wal"
	printf 'shm\n' > "$IDENTITY_PATH/clans.282.db-shm"
	printf 'blueprints\n' > "$IDENTITY_PATH/player.blueprints.16.db"
	printf 'older\n' > "$IDENTITY_PATH/sv.files.281.db"
	printf 'configuration\n' > "$IDENTITY_PATH/cfg/server.cfg"
	printf 'sibling\n' > "$SIBLING_IDENTITY_PATH/clans.282.db"

	run_no_wipe > /dev/null

	assert_not_exists "$IDENTITY_PATH/amazon.282.sav"
	assert_not_exists "$IDENTITY_PATH/clans.282.db"
	assert_exists "$IDENTITY_PATH/amazon.283.sav"
	assert_exists "$IDENTITY_PATH/amazon.283.sav.1"
	assert_exists "$IDENTITY_PATH/clans.283.db"
	assert_exists "$IDENTITY_PATH/clans.283.db-wal"
	assert_exists "$IDENTITY_PATH/clans.283.db-shm"
	assert_content "world-main" "$IDENTITY_PATH/amazon.283.sav"
	assert_exists "$IDENTITY_PATH/player.blueprints.16.db"
	assert_exists "$IDENTITY_PATH/sv.files.281.db"
	assert_exists "$SIBLING_IDENTITY_PATH/clans.282.db"

	completed_backup="$(find_completed_backup)"
	assert_exists "$completed_backup/server/main/amazon.282.sav"
	assert_exists "$completed_backup/server/main/clans.282.db-wal"
	assert_exists "$completed_backup/server/main/cfg/server.cfg"
	assert_exists "$completed_backup/server/sibling/clans.282.db"
	assert_contains "rust_save_version_from=282" "$completed_backup/manifest.txt"
	assert_contains "rust_save_version_to=283" "$completed_backup/manifest.txt"
	assert_contains "rust_build_id=24587531" "$completed_backup/manifest.txt"
	assert_contains "versioned_files=5" "$completed_backup/manifest.txt"
	pass "migration backs up the complete server tree and renames exact version tokens"
}

test_ambiguous_primary_saves()
{
	setup_case "ambiguous"
	printf 'first\n' > "$IDENTITY_PATH/amazon.282.sav"
	printf 'second\n' > "$IDENTITY_PATH/other.282.sav"

	if run_no_wipe > /dev/null 2>&1; then
		fail_test "ambiguous primary saves should fail"
	fi

	assert_exists "$IDENTITY_PATH/amazon.282.sav"
	assert_exists "$IDENTITY_PATH/other.282.sav"
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "ambiguous primary saves fail closed"
}

test_target_conflict()
{
	setup_case "conflict"
	printf 'world\n' > "$IDENTITY_PATH/amazon.282.sav"
	printf 'old-clans\n' > "$IDENTITY_PATH/clans.282.db"
	printf 'new-clans\n' > "$IDENTITY_PATH/clans.283.db"

	if run_no_wipe > /dev/null 2>&1; then
		fail_test "existing migration target should fail"
	fi

	assert_content "old-clans" "$IDENTITY_PATH/clans.282.db"
	assert_content "new-clans" "$IDENTITY_PATH/clans.283.db"
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "existing target files are never overwritten"
}

test_duplicate_migration_target()
{
	setup_case "duplicate-target"
	printf 'world\n' > "$IDENTITY_PATH/amazon.282.sav"
	printf 'first\n' > "$IDENTITY_PATH/data.282.283.db"
	printf 'second\n' > "$IDENTITY_PATH/data.283.282.db"

	if run_no_wipe > /dev/null 2>&1; then
		fail_test "duplicate migration targets should fail"
	fi

	assert_exists "$IDENTITY_PATH/data.282.283.db"
	assert_exists "$IDENTITY_PATH/data.283.282.db"
	assert_not_exists "$IDENTITY_PATH/data.283.283.db"
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "duplicate migration targets fail before backup or rename"
}

test_oxide_protocol_mismatch()
{
	setup_case "oxide-mismatch"
	printf 'world\n' > "$IDENTITY_PATH/amazon.282.sav"

	if run_no_wipe FAKE_OXIDE_PROTOCOL="2630.282.1" > /dev/null 2>&1; then
		fail_test "Rust and Oxide save version mismatch should fail"
	fi

	assert_exists "$IDENTITY_PATH/amazon.282.sav"
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "Rust and Oxide protocol mismatch fails before touching saves"
}

test_downgrade_blocked()
{
	setup_case "downgrade"
	printf 'future\n' > "$IDENTITY_PATH/amazon.284.sav"

	if run_no_wipe > /dev/null 2>&1; then
		fail_test "save downgrade should fail"
	fi

	assert_exists "$IDENTITY_PATH/amazon.284.sav"
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "save downgrade fails closed"
}

test_insufficient_backup_space()
{
	setup_case "space"
	printf 'world\n' > "$IDENTITY_PATH/amazon.282.sav"

	if run_no_wipe RUST_NO_WIPE_MIN_FREE_BYTES="999999999999999999" > /dev/null 2>&1; then
		fail_test "insufficient backup space should fail"
	fi

	assert_exists "$IDENTITY_PATH/amazon.282.sav"
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "insufficient backup space fails before migration"
}

test_backup_verification_failure()
{
	setup_case "backup-verification"
	printf 'world\n' > "$IDENTITY_PATH/amazon.282.sav"

	cat > "$FAKE_BIN_PATH/diff" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
	chmod +x "$FAKE_BIN_PATH/diff"

	if run_no_wipe > /dev/null 2>&1; then
		fail_test "backup verification failure should fail"
	fi

	assert_exists "$IDENTITY_PATH/amazon.282.sav"
	assert_not_exists "$IDENTITY_PATH/amazon.283.sav"
	assert_no_backup_artifacts "$BACKUP_ROOT_PATH"
	pass "failed full-backup verification removes the partial copy and preserves saves"
}

test_rust_version_extraction_ambiguity()
{
	setup_case "rust-version-ambiguity"
	printf 'world\n' > "$IDENTITY_PATH/amazon.282.sav"

	if run_no_wipe FAKE_SECOND_RUST_SAVE_VERSION="284" > /dev/null 2>&1; then
		fail_test "ambiguous Rust save constants should fail"
	fi

	assert_exists "$IDENTITY_PATH/amazon.282.sav"
	assert_no_completed_backup "$BACKUP_ROOT_PATH"
	pass "ambiguous Rust binary metadata fails closed"
}

test_rename_failure_rolls_back()
{
	local completed_backup

	setup_case "rollback"
	printf 'world\n' > "$IDENTITY_PATH/amazon.282.sav"
	printf 'world-backup\n' > "$IDENTITY_PATH/amazon.282.sav.1"
	printf 'clans\n' > "$IDENTITY_PATH/clans.282.db"

	cat > "$FAKE_BIN_PATH/mv" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

for argument in "$@"; do
	if [[ "$argument" == */server/main/amazon.282.sav.1 ]] && [ ! -e "${FAKE_MV_FAILURE_MARKER:?}" ]; then
		: > "$FAKE_MV_FAILURE_MARKER"
		exit 1
	fi
done

exec /usr/bin/mv "$@"
SCRIPT
	chmod +x "$FAKE_BIN_PATH/mv"

	if run_no_wipe FAKE_MV_FAILURE_MARKER="$CASE_ROOT/mv-failed" > /dev/null 2>&1; then
		fail_test "injected rename failure should fail"
	fi

	assert_exists "$IDENTITY_PATH/amazon.282.sav"
	assert_exists "$IDENTITY_PATH/amazon.282.sav.1"
	assert_exists "$IDENTITY_PATH/clans.282.db"
	assert_not_exists "$IDENTITY_PATH/amazon.283.sav"
	assert_not_exists "$IDENTITY_PATH/clans.283.db"
	completed_backup="$(find_completed_backup)"
	assert_exists "$completed_backup/server/main/amazon.282.sav"
	pass "rename failure rolls back filenames and preserves completed backup"
}

test_cached_binary_metadata()
{
	setup_case "cache"
	printf 'world\n' > "$IDENTITY_PATH/amazon.283.sav"
	run_no_wipe > /dev/null

	cat > "$FAKE_BIN_PATH/monodis" <<'SCRIPT'
#!/usr/bin/env bash
exit 97
SCRIPT
	cat > "$FAKE_BIN_PATH/curl" <<'SCRIPT'
#!/usr/bin/env bash
exit 98
SCRIPT
	chmod +x "$FAKE_BIN_PATH/monodis" "$FAKE_BIN_PATH/curl"

	run_no_wipe > /dev/null
	assert_exists "$IDENTITY_PATH/amazon.283.sav"
	pass "verified metadata cache is keyed by assembly hashes"
}

test_disabled_mode
test_first_start_without_save
test_current_save_version
test_successful_migration
test_ambiguous_primary_saves
test_target_conflict
test_duplicate_migration_target
test_oxide_protocol_mismatch
test_downgrade_blocked
test_insufficient_backup_space
test_backup_verification_failure
test_rust_version_extraction_ambiguity
test_rename_failure_rolls_back
test_cached_binary_metadata

printf 'All %s no-wipe tests passed.\n' "$PASSED_TESTS"
