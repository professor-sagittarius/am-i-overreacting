# Nextcloud Migration Guide

This guide covers migrating an existing Nextcloud instance to the stack provisioned by this
repository. The migration preserves all user files, accounts, shares, and app data.

## Overview

The migration has three phases:

1. **Export** (OLD HOST) - export.sh puts your old instance in maintenance mode and exports
   the database and configuration values
2. **Transfer** (your workstation or the NEW HOST) - rsync the export bundle and user files
   directly to the new server
3. **Import** (NEW HOST) - import.sh restores the database, applies configuration, and runs
   post-migration repair commands

---

## Before You Begin

### Take a full backup of the old host

**Do this before anything else.** Take a VM snapshot or full backup of the old host. If
something goes wrong during migration, this is your only way to fully recover.

### Verify the new stack is working

Before importing old data, confirm the new stack is running correctly:

1. Complete the new stack setup: run `generate-passwords.sh`, fill in `nextcloud/.env`,
   and start the services with `docker compose -f nextcloud/docker-compose.yaml up -d`
2. Log in to Nextcloud with the generated admin credentials from
   `nextcloud/secrets/admin_password`
3. Confirm it works, then proceed with migration

### Version must match exactly

Nextcloud will refuse to start if the version of your old instance does not exactly match
the version pinned in this stack's `nextcloud/docker-compose.yaml`. Even a minor version
difference will cause a failure.

If your versions differ, you have two options:

- **Upgrade the old instance** to match the version in this stack, then migrate
- **Change the image tag** in `nextcloud/docker-compose.yaml` to match the old version,
  complete the migration, then upgrade via the normal Nextcloud upgrade procedure

### Check available disk space on the new host

User files are rsynced directly to their final destination, so only one copy of the data
will exist on the new host at any time. However, the new host still needs enough space for:
- The Nextcloud data volume (user files)
- The export bundle (database dump - much smaller than the data volume)

---

## Step 1: Export (OLD HOST)

Copy `export.sh` to your old host, then run it:

```bash
# OLD HOST
bash export.sh
```

The script will:
- Enable maintenance mode (Nextcloud goes offline)
- Check for server-side encryption and TOTP 2FA
- Export the database (PostgreSQL, MySQL/MariaDB, or SQLite)
- Extract critical configuration values (instanceid, passwordsalt, secret)
- Write everything to `nc-migration-export/`
- Print the rsync commands to use in Step 2

**Options:**

```bash
bash export.sh --dry-run          # Preview without making changes
bash export.sh --verbose          # Show detailed output
bash export.sh --container NAME   # Specify container name if auto-detection fails
bash export.sh --output-dir DIR   # Write export to a custom directory
```

**Supported source environments:**
- Nextcloud AIO (auto-detected as `nextcloud-aio-nextcloud` or `*-nextcloud`)
- This stack (`nextcloud_app`)
- Other Docker setups (`nextcloud-app`, `nextcloud`, `nextcloud-web`)
- Bare-metal installs in standard paths

After export.sh finishes, your old Nextcloud remains in maintenance mode. **Leave it in
maintenance mode until the new server is verified and DNS is switched.**

---

## Step 2: Transfer (NEW HOST)

Run these commands from the **NEW HOST** to pull the files from the old host. The export
script also prints these commands with the correct paths filled in.

```bash
# NEW HOST - transfer the export bundle (small - contains database and config)
rsync -avz --progress user@OLD_HOST:~/nc-migration-export/ ./nc-migration-export/

# NEW HOST - transfer user files directly to the final data volume location
# Find NEXTCLOUD_DATA_VOLUME in nextcloud/.env (default: /var/lib/nextcloud/data)
rsync -avz --progress -t \
    user@OLD_HOST:/path/to/nextcloud/data/ \
    /var/lib/nextcloud/data/
```

Replace `user@OLD_HOST` with your SSH credentials for the old server, and
`/path/to/nextcloud/data/` with the data directory path printed by `export.sh`.

> **Note on the `-t` flag:** This preserves file modification timestamps, which ensures
> Nextcloud sync clients correctly detect what has and has not changed.

> **Note on the trailing slashes:** The trailing `/` after both the source and destination
> paths is intentional - it tells rsync to copy the *contents* of the directory, not the
> directory itself.

The data transfer can take a long time for large instances. You can safely pause and resume
rsync - it will skip files that already transferred correctly.

---

## Step 3: Import (NEW HOST)

From the repository root on the NEW HOST:

```bash
# NEW HOST
bash nextcloud/migrate/import.sh
```

The script will:
1. Verify prerequisites and version compatibility
2. Import the database (restoring it into the new PostgreSQL instance)
3. Fix file ownership on the data volume
4. Start the Nextcloud app container
5. Apply the old instance's configuration values (instanceid, passwordsalt, secret)
6. Offer to reset the admin password to the new stack's generated password
7. Run post-import maintenance commands
8. Print the post-migration checklist
9. Offer to remove the export bundle

**Options:**

```bash
bash nextcloud/migrate/import.sh --dry-run      # Preview without making changes
bash nextcloud/migrate/import.sh --verbose      # Show detailed output
bash nextcloud/migrate/import.sh --export-dir DIR  # Use export bundle from custom path
```

### Database migration paths

| Old database    | New database | Notes |
|-----------------|--------------|-------|
| PostgreSQL      | PostgreSQL   | Fully automated - credentials remapped automatically |
| MySQL/MariaDB   | PostgreSQL   | Requires `pgloader` (`apt-get install pgloader`) |
| SQLite          | PostgreSQL   | Not directly supported - convert to MySQL on old host first using `occ db:convert-type` |

### Admin password after migration

After the database is imported, the admin account's password is the **old system's admin
password** - not the one generated by this stack. The import script will offer to reset it
to the new stack's generated password (stored in `nextcloud/secrets/admin_password`).

If you have TOTP two-factor authentication enabled, make sure you have your authenticator
app available before logging in.

---

## Step 4: Post-migration checklist

After the import script completes, work through these steps:

- [ ] **Verify the migration** - log in to the new Nextcloud, confirm files are visible,
  check Settings > Administration > Overview for any warnings
- [ ] **OLD HOST** - disable maintenance mode so users get a proper error (rather than a
  maintenance page) if they hit the old server:
  ```bash
  docker exec -u www-data nextcloud_app php occ maintenance:mode --off
  ```
- [ ] **DNS** - update your Nextcloud domain's DNS record to point to the Cloudflare tunnel
  of the **new** host. Find the tunnel connector hostname in the Cloudflare dashboard under
  Zero Trust > Networks > Tunnels.
- [ ] **Monitor** - watch the new instance logs for errors after the DNS change takes effect:
  ```bash
  docker compose -f nextcloud/docker-compose.yaml logs -f nextcloud_app
  ```
- [ ] **Cloudflare** - once satisfied, revoke the old host's tunnel token in the Cloudflare
  dashboard
- [ ] **External storage** - if the old instance had external storage configured,
  reconfigure those connections on the new instance:
  Settings > Administration > External Storages
- [ ] **Decommission** old host (power off / delete VM)

---

## Troubleshooting

### Files appear missing after login

The file index may need to be rebuilt. This is safe to run but can be slow on large instances:

```bash
# NEW HOST
docker exec -u www-data nextcloud_app php occ files:scan --all
```

### Nextcloud won't start after import

Check the logs:

```bash
docker compose -f nextcloud/docker-compose.yaml logs nextcloud_app
```

Common causes:
- **Version mismatch** - see "Version must match exactly" above
- **Wrong instanceid/secret** - the import script sets these from the manifest; if they
  are wrong, the app will fail with a "configuration is invalid" error. Verify the values
  in `nc-migration-export/manifest.json` match your old instance's `config.php`.

### Database restore failed

If `pg_restore` failed partway through, the database may be in a partial state. Drop and
recreate it, then retry the import:

```bash
# NEW HOST
docker exec -e PGPASSWORD="$(cat nextcloud/secrets/postgres_password)" \
    nextcloud_postgres psql -U oc_nextcloud -d postgres \
    -c "DROP DATABASE IF EXISTS nextcloud_database; CREATE DATABASE nextcloud_database;"
```

Then re-run the import script.

### MySQL migration with pgloader fails

The generated pgloader config is saved to `/tmp/nc-migration-pgloader.load`. Review it,
fix any connection details, and run pgloader manually:

```bash
pgloader /tmp/nc-migration-pgloader.load
```

---

## What is and is not migrated

| Migrated | Not migrated |
|----------|--------------|
| All user accounts and passwords | Nextcloud app code (Docker image provides this) |
| User files and folder structure | `config.php` (managed by before-startup.sh) |
| Shares and public links | Redis cache and sessions |
| Calendar, contacts, tasks | Log files |
| App data (Talk, Notes, etc.) | Server-side encryption keys (see warning) |
| Admin settings stored in the database | |
| instanceid, passwordsalt, secret | |

### Server-side encryption

If server-side encryption is enabled on the old instance, `export.sh` will detect it and
abort with an error. Migrating encrypted data requires careful handling of master keys that
is outside the scope of these scripts. Refer to the Nextcloud encryption migration
documentation before proceeding.
