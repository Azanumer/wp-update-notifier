# WordPress Update Notifier

Check a WordPress site for pending core, plugin and theme updates with WP-CLI — a human-readable table, `--json` for monitoring, and an optional email digest. Exit codes are Nagios-friendly: 0 = up to date, 1 = updates available, 2 = error.

## Features

- **One command** — `./check-wp-updates.sh --path /var/www/html` reports everything pending.
- **Core + plugins + themes** — uses `wp core check-update`, `wp plugin list --update=available` and `wp theme list --update=available`.
- **Nagios exit codes** — 0 up to date, 1 updates pending, 2 error (wp-cli missing, not a WordPress install, bad arguments).
- **JSON output** — `--json` prints a machine-readable report for monitoring or dashboards.
- **Email digest** — `--to admin@example.com` mails the pending list (via `mail`, falling back to `sendmail`); nothing is mailed when the site is up to date.
- **Exclusions** — `--exclude slug` ignores a plugin or theme you deliberately keep pinned (repeatable).
- **Safe parsing** — wp-cli JSON is parsed with python3; a malformed response degrades to "no updates" for that section instead of crashing the run.

## Usage

```bash
# Check a site:
./check-wp-updates.sh --path /var/www/html

# JSON for monitoring:
./check-wp-updates.sh --path /var/www/html --json

# Daily 07:00 email digest (cron):
0 7 * * * /opt/scripts/check-wp-updates.sh --path /var/www/html --to admin@example.com

# Ignore a deliberately pinned plugin:
./check-wp-updates.sh --path /var/www/html --exclude classic-editor
```

## Requirements

- WP-CLI (`wp`) in PATH
- python3 (JSON parsing)
- `mail` or `sendmail` (only with `--to`)

## License

MIT — see [LICENSE](LICENSE).
