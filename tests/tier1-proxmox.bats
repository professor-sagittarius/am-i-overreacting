#!/usr/bin/env bats
# Tier 1: Unit tests for Proxmox scripts. No Docker or Proxmox required.

setup() {
	load 'lib/bats-support/load'
	load 'lib/bats-assert/load'
	load 'helpers/common.bash'
	load 'helpers/proxmox.bash'
	setup_proxmox_mocks
}
