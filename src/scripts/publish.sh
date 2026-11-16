#!/bin/sh
# Publish a file, page or site to BrewPage from CI; BREWPAGE_* env config, POSIX sh + curl, jq optional.

bp_nl='
'
bp_cr=$(printf '\r')

bp_err() {
  printf 'brewpage: error: %s\n' "$*" >&2
}

# Top-level string field of a JSON file; jq when present, else first key match.
bp_field() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" 'if type == "object" then (.[$k] // empty | tostring) else empty end' "$1" 2>/dev/null || true
  else
    tr -d '\n' < "$1" | grep -o "\"$2\" *: *\"[^\"]*\"" | head -n 1 | sed 's/^"[^"]*" *: *"//; s/"$//' || true
  fi
}

bp_notices() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.notices[]? | "brewpage: notice: \(.code // "") \(.message // "")"' "$1" 2>/dev/null || true
  else
    tr -d '\n' < "$1" | grep -o '"message" *: *"[^"]*"' | sed 's/^"message" *: *"/brewpage: notice: /; s/"$//' || true
  fi
}

bp_has_ctl() {
  case $1 in *"$bp_nl"* | *"$bp_cr"*) return 0 ;; esac
  return 1
}

# Value of the env var named $1 (secrets passed by name, as CI parameter types require).
bp_indirect() {
  case $1 in
    '' | [0-9]* | *[!A-Za-z0-9_]*) bp_err "not an environment variable name: $1"; return 2 ;;
  esac
  eval "printf '%s' \"\${$1:-}\""
}

bp_out() {
  case $2 in
    '' | *[!A-Za-z0-9:/._%+~=-]*) [ -z "$2" ] || bp_err "skipping $1 in output file: unexpected characters" ;;
    *) printf '%s=%s\n' "$1" "$2" >> "$BREWPAGE_OUTPUT_FILE" ;;
  esac
}

bp_main() (
  set -eu
  path=${BREWPAGE_PATH:-}
  kind=${BREWPAGE_KIND:-auto}
  ns=${BREWPAGE_NAMESPACE:-}
  ttl=${BREWPAGE_TTL:-}
  tags=${BREWPAGE_TAGS:-}
  entry=${BREWPAGE_ENTRY:-}
  token=${BREWPAGE_OWNER_TOKEN:-}
  password=${BREWPAGE_PASSWORD:-}
  [ -z "${BREWPAGE_OWNER_TOKEN_VAR:-}" ] || token=$(bp_indirect "$BREWPAGE_OWNER_TOKEN_VAR") || exit 2
  [ -z "${BREWPAGE_PASSWORD_VAR:-}" ] || password=$(bp_indirect "$BREWPAGE_PASSWORD_VAR") || exit 2
  base=${BREWPAGE_API_URL:-https://brewpage.app}
  base=${base%/}
  client=${BREWPAGE_CLIENT:-brewpage-ci/1.0.0}

  [ -n "$path" ] || { bp_err "path is required"; exit 2; }
  [ "$path" = / ] || path=${path%/}
  [ -e "$path" ] || { bp_err "path not found: $path"; exit 2; }
  case $path in *\"* | *\\*) bp_err "path must not contain quotes or backslashes"; exit 2 ;; esac
  if bp_has_ctl "$path"; then bp_err "path must be one line"; exit 2; fi
  case $ns in *[!a-z0-9-]*) bp_err "namespace: lowercase letters, digits and '-' only"; exit 2 ;; esac
  [ "${#ns}" -le 32 ] || { bp_err "namespace: at most 32 characters"; exit 2; }
  case $ttl in *[!0-9]*) bp_err "ttl: whole days only"; exit 2 ;; esac
  case $tags in *[!A-Za-z0-9,_.-]*) bp_err "tags: comma-separated words (letters, digits, '_', '.', '-')"; exit 2 ;; esac
  case $entry in *[!A-Za-z0-9._/-]*) bp_err "entry: a relative file path"; exit 2 ;; esac
  if bp_has_ctl "$token$password"; then bp_err "owner token and password must be one line"; exit 2; fi
  case $base in http://* | https://*) ;; *) bp_err "api url must start with http:// or https://"; exit 2 ;; esac

  case $kind in
    auto) if [ -d "$path" ]; then kind='site'; else kind='file'; fi ;;
    file) [ -f "$path" ] || { bp_err "kind file needs a regular file"; exit 2; } ;;
    site) ;;
    *) bp_err "kind: auto, file or site"; exit 2 ;;
  esac

  query=
  [ -z "$ns" ] || query="${query}&ns=$ns"
  [ -z "$ttl" ] || query="${query}&ttl=$ttl"
  [ -z "$tags" ] || query="${query}&tags=$tags"
  [ "$kind" != site ] || [ -z "$entry" ] || query="${query}&entry=$entry"
  query=${query#&}

  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t brewpage)
  trap 'rm -rf "$tmp"' EXIT
  : > "$tmp/headers"
  chmod 600 "$tmp/headers"
  [ -z "$token" ] || printf 'X-Owner-Token: %s\n' "$token" >> "$tmp/headers"
  [ -z "$password" ] || printf 'X-Password: %s\n' "$password" >> "$tmp/headers"

  set -- -sS -X POST -o "$tmp/body" -D "$tmp/resp-headers" -w '%{http_code}' \
    -A "$client (+https://brewpage.app)" -H 'Accept: application/json' -H "@$tmp/headers"
  if [ "$kind" = file ]; then
    endpoint=files
    set -- "$@" -F "file=@\"$path\""
  elif [ -f "$path" ]; then
    endpoint=sites
    set -- "$@" -F "archive=@\"$path\""
  else
    endpoint=sites
    find "$path" -type f > "$tmp/list"
    [ -s "$tmp/list" ] || { bp_err "no files in $path"; exit 2; }
    while IFS= read -r f; do
      case $f in *\"* | *\\*) bp_err "file name with quotes or backslashes: $f"; exit 2 ;; esac
      set -- "$@" -F "files=@\"$f\"" --form-string "paths=${f#"$path"/}"
    done < "$tmp/list"
  fi
  url="$base/api/$endpoint"
  [ -z "$query" ] || url="$url?$query"

  printf 'brewpage: publishing %s (%s) to %s\n' "$path" "$kind" "$base"
  if ! code=$(curl "$@" "$url"); then
    bp_err "request to $base failed"
    exit 1
  fi

  case $code in
    2??) ;;
    429)
      wait=$(tr -d '\r' < "$tmp/resp-headers" | sed -n 's/^[Rr]etry-[Aa]fter: *//p' | head -n 1)
      bp_err "rate limited (HTTP 429); retry after ${wait:-a while} s"
      exit 1
      ;;
    *)
      bp_err "HTTP $code: $(bp_field "$tmp/body" code) $(bp_field "$tmp/body" error)"
      head -c 600 "$tmp/body" >&2 || true
      printf '\n' >&2
      exit 1
      ;;
  esac

  link=$(bp_field "$tmp/body" link)
  manage=$(bp_field "$tmp/body" manageUrl)
  [ -n "$link" ] || { bp_err "answer has no link"; exit 1; }
  printf 'brewpage: link: %s\n' "$link"
  if [ "${BREWPAGE_SHOW_MANAGE_URL:-true}" = true ] && [ -n "$manage" ]; then
    printf 'brewpage: manage link (private: anyone who has it can edit or delete): %s\n' "$manage"
  fi
  printf 'brewpage: expires: %s\n' "$(bp_field "$tmp/body" expiresAt)"
  bp_notices "$tmp/body"
  [ -n "$token" ] || printf 'brewpage: tip: set an owner token secret to keep your publications under one owner\n'

  if [ -n "${BREWPAGE_OUTPUT_FILE:-}" ]; then
    bp_out BREWPAGE_LINK "$link"
    bp_out BREWPAGE_ID "$(bp_field "$tmp/body" id)"
    bp_out BREWPAGE_NAMESPACE "$(bp_field "$tmp/body" namespace)"
    bp_out BREWPAGE_EXPIRES_AT "$(bp_field "$tmp/body" expiresAt)"
  fi
)

bp_main
