#!/usr/bin/env bash
# Entry point: ./tests/run-tests.sh [tier1|tier2|tier3|all]
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BATS="$TESTS_DIR/lib/bats-core/bin/bats"

usage() {
	echo "Usage: $0 [tier1|tier2|tier3|all]"
	echo ""
	echo "  tier1  Static analysis (CI-safe, no Docker required)"
	echo "  tier2  Stack health integration tests (requires Docker)"
	echo "  tier3  Migration end-to-end test (requires Docker, ~10min)"
	echo "  all    Run all tiers"
	exit 1
}

TIER="${1:-all}"

# Warn before running tier 2 or 3 on a machine that may have production stacks.
_warn_destructive() {
	echo ""
	echo "WARNING: Tier 2 and 3 tests are NOT safe to run on a production machine."
	echo ""
	echo "  - They start containers with the same names as production stacks"
	echo "    (nextcloud_app, nextcloud_postgres, gitea_app, etc.)."
	echo "  - They tear down stacks with 'docker compose down -v', which"
	echo "    DELETES VOLUMES on any project that shares the same compose file."
	echo "  - They bind the same ports as production (8888, 3000, etc.)."
	echo ""
	echo "Run these tiers on a dedicated test machine only."
	echo ""
	read -r -p "Continue anyway? [y/N] " _resp
	echo ""
	case "${_resp,,}" in
	y | yes) ;;
	*)
		echo "Aborted."
		exit 1
		;;
	esac
}

case "$TIER" in
tier1) "$BATS" "$TESTS_DIR/tier1-static.bats" ;;
tier2)
	_warn_destructive
	"$BATS" "$TESTS_DIR/tier2-stacks.bats"
	;;
tier3)
	_warn_destructive
	"$BATS" "$TESTS_DIR/tier3-migration.bats"
	;;
all)
	_warn_destructive
	"$BATS" \
		"$TESTS_DIR/tier1-static.bats" \
		"$TESTS_DIR/tier2-stacks.bats" \
		"$TESTS_DIR/tier3-migration.bats"
	;;
*) usage ;;
esac
