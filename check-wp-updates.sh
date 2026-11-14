#!/usr/bin/env bash
# check-wp-updates.sh — report pending WordPress core / plugin / theme updates.
#
# Uses WP-CLI (wp) against one site and prints a human-readable summary,
# or --json for monitoring. Optionally emails a digest with --to.
#
# Exit codes (Nagios-friendly):
#   0  everything up to date
#   1  updates available
#   2  error (wp-cli missing, not a WordPress install, bad arguments)
#
# Usage:
#   ./check-wp-updates.sh --path /var/www/html [--json] [--to admin@example.com]
#                          [--exclude akismet --exclude hello.php] [--quiet]
#
# Cron example (daily 07:00 digest):
#   0 7 * * * /opt/scripts/check-wp-updates.sh --path /var/www/html --to admin@example.com
#
# Requires: wp (WP-CLI), python3 (JSON parsing), mail or sendmail (only with --to).

set -euo pipefail

PATH_TO_CHECK=""
JSON_OUTPUT=0
QUIET=0
MAIL_TO=""
EXCLUDE=()

usage() {
    cat <<'EOF'
Usage: check-wp-updates.sh --path /path/to/wordpress [options]

Options:
  --path DIR        WordPress install to check (required)
  --json            Print machine-readable JSON instead of a table
  --to EMAIL        Email a digest of pending updates (exit code unchanged)
  --exclude SLUG    Ignore this plugin/theme slug (repeatable)
  --quiet           Print only the one-line summary
  --help            Show this help
EOF
}

log() {
    if [[ "${QUIET}" -eq 0 ]]; then
        printf '%s\n' "$*"
    fi
}

# --- Parse arguments -------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            [[ $# -ge 2 ]] || { echo "error: --path needs a value" >&2; usage >&2; exit 2; }
            PATH_TO_CHECK="$2"; shift 2 ;;
        --json)   JSON_OUTPUT=1; shift ;;
        --quiet)  QUIET=1; shift ;;
        --to)
            [[ $# -ge 2 ]] || { echo "error: --to needs a value" >&2; usage >&2; exit 2; }
            MAIL_TO="$2"; shift 2 ;;
        --exclude)
            [[ $# -ge 2 ]] || { echo "error: --exclude needs a value" >&2; usage >&2; exit 2; }
            EXCLUDE+=("$2"); shift 2 ;;
        --help) usage; exit 0 ;;
        *)
            echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "${PATH_TO_CHECK}" ]] || { echo "error: --path is required" >&2; usage >&2; exit 2; }
[[ -d "${PATH_TO_CHECK}" ]] || { echo "error: ${PATH_TO_CHECK} is not a directory" >&2; exit 2; }

command -v wp >/dev/null 2>&1 || { echo "error: wp (WP-CLI) not found in PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found (needed to parse wp-cli JSON)" >&2; exit 2; }

# Confirm this really is a WordPress install before running anything else.
if ! wp core is-installed --path="${PATH_TO_CHECK}" --quiet 2>/dev/null; then
    echo "error: ${PATH_TO_CHECK} is not an installed WordPress site" >&2
    exit 2
fi

is_excluded() {
    local slug="$1"
    local item
    for item in "${EXCLUDE[@]:-}"; do
        [[ "${item}" == "${slug}" ]] && return 0
    done
    return 1
}

# --- Collect updates -------------------------------------------------------
# Each list holds lines: "type|slug|name|current|available"
UPDATES=()

# Core: wp core check-update --format=json prints [] when up to date,
# otherwise objects with version + update_type.
CORE_JSON="$(wp core check-update --path="${PATH_TO_CHECK}" --format=json 2>/dev/null || echo '[]')"
CORE_LINE="$(printf '%s' "${CORE_JSON}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if isinstance(data, list) and data:
    item = data[0]
    print("core|wordpress|WordPress|%s|%s" % (item.get("current_version", "?"), item.get("version", "?")))
' || true)"
[[ -n "${CORE_LINE}" ]] && UPDATES+=("${CORE_LINE}")

# Plugins: wp plugin list --update=available --format=json
PLUGIN_JSON="$(wp plugin list --update=available --path="${PATH_TO_CHECK}" --format=json 2>/dev/null || echo '[]')"
while IFS= read -r line; do
    [[ -n "${line}" ]] && UPDATES+=("${line}")
done < <(printf '%s' "${PLUGIN_JSON}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if isinstance(data, list):
    for item in data:
        print("plugin|%s|%s|%s|%s" % (
            item.get("name", "?"),
            item.get("title", item.get("name", "?")),
            item.get("version", "?"),
            item.get("update_version", "?"),
        ))
' || true)

# Themes: wp theme list --update=available --format=json
THEME_JSON="$(wp theme list --update=available --path="${PATH_TO_CHECK}" --format=json 2>/dev/null || echo '[]')"
while IFS= read -r line; do
    [[ -n "${line}" ]] && UPDATES+=("${line}")
done < <(printf '%s' "${THEME_JSON}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
if isinstance(data, list):
    for item in data:
        print("theme|%s|%s|%s|%s" % (
            item.get("name", "?"),
            item.get("title", item.get("name", "?")),
            item.get("version", "?"),
            item.get("update_version", "?"),
        ))
' || true)

# --- Apply exclusions ------------------------------------------------------
FILTERED=()
for entry in "${UPDATES[@]:-}"; do
    [[ -z "${entry}" ]] && continue
    slug="$(printf '%s' "${entry}" | cut -d'|' -f2)"
    if is_excluded "${slug}"; then
        continue
    fi
    FILTERED+=("${entry}")
done
# Plain "${FILTERED[@]}" (no :-) so an empty list stays empty — with :-
# an empty array would expand to one empty string and fake one update.
UPDATES=("${FILTERED[@]}")

COUNT="${#UPDATES[@]}"
SITE_URL="$(wp option get siteurl --path="${PATH_TO_CHECK}" 2>/dev/null || echo "${PATH_TO_CHECK}")"

# --- Output ----------------------------------------------------------------
if [[ "${JSON_OUTPUT}" -eq 1 ]]; then
    {
        printf '{\n  "site": "%s",\n  "path": "%s",\n  "updates_available": %s,\n  "updates": [\n' \
            "${SITE_URL}" "${PATH_TO_CHECK}" "${COUNT}"
        first=1
        for entry in "${UPDATES[@]:-}"; do
            [[ -z "${entry}" ]] && continue
            IFS='|' read -r type slug name current available <<< "${entry}"
            [[ "${first}" -eq 0 ]] && printf ',\n'
            first=0
            # Values come from wp-cli, not the user, but escape quotes anyway.
            printf '    {"type": "%s", "slug": "%s", "name": "%s", "current": "%s", "available": "%s"}' \
                "${type}" "${slug}" "${name//\"/\\\"}" "${current}" "${available}"
        done
        printf '\n  ]\n}\n'
    }
else
    if [[ "${COUNT}" -eq 0 ]]; then
        log "OK: ${SITE_URL} is up to date (core, plugins, themes)."
    else
        log "UPDATES AVAILABLE (${COUNT}) — ${SITE_URL}"
        printf '%-8s %-28s %-12s %-12s\n' "TYPE" "NAME" "CURRENT" "AVAILABLE"
        for entry in "${UPDATES[@]:-}"; do
            [[ -z "${entry}" ]] && continue
            IFS='|' read -r type slug name current available <<< "${entry}"
            printf '%-8s %-28s %-12s %-12s\n' "${type}" "${name}" "${current}" "${available}"
        done
    fi
fi

# --- Optional email digest -------------------------------------------------
if [[ -n "${MAIL_TO}" && "${COUNT}" -gt 0 ]]; then
    BODY="WordPress updates pending for ${SITE_URL} (${PATH_TO_CHECK}):\n\n"
    for entry in "${UPDATES[@]:-}"; do
        [[ -z "${entry}" ]] && continue
        IFS='|' read -r type slug name current available <<< "${entry}"
        BODY+="- [${type}] ${name}: ${current} -> ${available}\n"
    done
    BODY+="\nReview and update from wp-admin, or run: wp core update && wp plugin update --all && wp theme update --all --path=${PATH_TO_CHECK}\n"
    SUBJECT="[WP Updates] ${COUNT} update(s) pending — ${SITE_URL}"
    if command -v mail >/dev/null 2>&1; then
        printf '%b' "${BODY}" | mail -s "${SUBJECT}" "${MAIL_TO}" 2>/dev/null || echo "warning: mail failed" >&2
    elif command -v sendmail >/dev/null 2>&1; then
        {
            printf 'To: %s\nSubject: %s\n\n' "${MAIL_TO}" "${SUBJECT}"
            printf '%b' "${BODY}"
        } | sendmail -t 2>/dev/null || echo "warning: sendmail failed" >&2
    else
        echo "warning: --to given but neither mail nor sendmail is available" >&2
    fi
fi

# --- Exit code -------------------------------------------------------------
if [[ "${COUNT}" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
