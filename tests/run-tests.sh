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

case "$TIER" in
tier1) "$BATS" "$TESTS_DIR/tier1-static.bats" ;;
tier2) "$BATS" "$TESTS_DIR/tier2-stacks.bats" ;;
tier3) "$BATS" "$TESTS_DIR/tier3-migration.bats" ;;
all)
	"$BATS" \
		"$TESTS_DIR/tier1-static.bats" \
		"$TESTS_DIR/tier2-stacks.bats" \
		"$TESTS_DIR/tier3-migration.bats"
	;;
*) usage ;;
esac
