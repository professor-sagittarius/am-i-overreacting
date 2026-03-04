#!/usr/bin/env bats
# Tier 1: Static analysis tests. No Docker required. Runs in CI.

setup() {
	load 'lib/bats-support/load'
	load 'lib/bats-assert/load'
	load 'helpers/common.bash'
}

# -- shellcheck ----------------------------------------------------------------

@test "shellcheck: all shell scripts pass at warning severity" {
	run find "$REPO_ROOT" -name "*.sh" \
		-not -path "*/.git/*" \
		-not -path "*/tests/lib/*"

	local scripts=("${lines[@]}")
	[[ ${#scripts[@]} -gt 0 ]] || fail "No shell scripts found"

	run shellcheck -S warning "${scripts[@]}"
	assert_success
}

# -- shfmt ---------------------------------------------------------------------

@test "shfmt: no formatting drift in shell scripts" {
	local unformatted
	unformatted=$(find "$REPO_ROOT" -name "*.sh" \
		-not -path "*/.git/*" \
		-not -path "*/tests/lib/*" \
		| xargs shfmt -l)

	if [[ -n "$unformatted" ]]; then
		echo "Files with formatting drift (run 'shfmt -w' to fix):"
		echo "$unformatted"
		return 1
	fi
}
