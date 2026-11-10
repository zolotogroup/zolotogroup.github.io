#!/usr/bin/env bash
# Publish a GitHub Pages artifact without the 10-minute abort in actions/deploy-pages.
#
# That action clamps `timeout` to 600000 ms and, when the clock runs out, cancels
# the deployment. A build that is still deployment_queued or syncing_files is
# thrown away and the site stays on the previous commit.
#
# This script creates at most one extra deployment of the full artifact uploaded
# in this run, then polls it. It does not call the Pages cancel endpoint when a
# wait expires. A second job (or a later rerun of this workflow) resumes the
# same deployment id until Pages reports success. The site changes only when
# that status is succeed, so a half-synced deploy is not what goes live.
set -euo pipefail

MODE="${PAGES_MODE:-finish}"
WAIT_SEC="${PAGES_WAIT_SEC:-600}"
ABSENT_SEC="${PAGES_ABSENT_SEC:-90}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
SHA="${GITHUB_SHA:?GITHUB_SHA is required}"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
API="https://api.github.com/repos/${REPO}"

LAST_CODE=""
LAST_BODY=""

log() { printf '%s\n' "$*" >&2; }

now() { date +%s; }

pause() { sleep "${PAGES_POLL_SEC:-15}"; }

set_output() {
  local key="$1" value="$2"
  log "output ${key}=${value}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
}

api() {
  local method="$1" url="$2" data="${3-}"
  local tmp code curl_rc
  tmp="$(mktemp)"
  set +e
  if [ -n "$data" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      --data "$data" \
      "$url")"
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url")"
  fi
  curl_rc=$?
  set -e
  if [ "$curl_rc" -ne 0 ]; then
    rm -f "$tmp"
    LAST_CODE=0
    LAST_BODY=""
    return 1
  fi
  LAST_CODE="$code"
  LAST_BODY="$(cat "$tmp")"
  rm -f "$tmp"
}

kind_of() {
  local code="$1" status="$2"
  case "$code" in
    401|403) printf 'denied\n'; return ;;
    404) printf 'missing\n'; return ;;
  esac
  case "$status" in
    succeed|success) printf 'live\n' ;;
    deployment_failed|deployment_content_failed|deployment_cancelled|deployment_canceled|deployment_lost)
      printf 'terminal\n'
      ;;
    "") printf 'unknown\n' ;;
    *) printf 'syncing\n' ;;
  esac
}

# Sets KIND in the current shell. Do not call this inside $(...), or the
# response body is discarded with the subshell.
fetch() {
  local id="$1" status
  KIND=unknown
  if ! api GET "${API}/pages/deployments/${id}"; then
    log "deployment ${id}: request failed"
    return
  fi
  status="$(printf '%s' "$LAST_BODY" | jq -r '.status // empty' 2>/dev/null || true)"
  log "deployment ${id}: http ${LAST_CODE} status ${status:-<empty>}"
  KIND="$(kind_of "$LAST_CODE" "$status")"
}

page_url() {
  local url
  url="$(printf '%s' "$LAST_BODY" | jq -r '.page_url // empty' 2>/dev/null || true)"
  if [ -z "$url" ]; then
    url="https://zolotogroup.github.io/"
  fi
  printf '%s' "$url"
}

finish_live() {
  local id="$1"
  set_output page_url "$(page_url)"
  set_output deployment_id "$id"
  set_output result live
}

main_head() {
  if ! api GET "${API}/commits/main"; then
    printf '\n'
    return
  fi
  if [ "$LAST_CODE" != "200" ]; then
    printf '\n'
    return
  fi
  printf '%s' "$LAST_BODY" | jq -r '.sha // empty'
}

artifact_id() {
  if [ -n "${PAGES_ARTIFACT_ID:-}" ]; then
    printf '%s' "$PAGES_ARTIFACT_ID"
    return
  fi
  if ! api GET "${API}/actions/runs/${GITHUB_RUN_ID}/artifacts"; then
    return 1
  fi
  printf '%s' "$LAST_BODY" | jq -r '[.artifacts[] | select(.name=="github-pages" and .expired==false)] | sort_by(.id) | last | .id // empty'
}

oidc_token() {
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    log "OIDC request is unavailable. The finish job needs id-token: write."
    return 1
  fi
  curl -fsS \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}" | jq -r '.value'
}

# Poll one deployment until it is live, terminal, or the deadline passes.
# Returns 0 live, 2 terminal, 10 still syncing. Does not cancel.
poll_id() {
  local id="$1" deadline="$2"
  while :; do
    fetch "$id"
    case "$KIND" in
      live)
        finish_live "$id"
        return 0
        ;;
      terminal)
        set_output deployment_id "$id"
        return 2
        ;;
      denied)
        log "Pages API denied a status read for ${id}."
        return 1
        ;;
      *)
        if [ "$(now)" -ge "$deadline" ]; then
          log "Deployment ${id} is still ${KIND} after this wait. Leaving it running."
          set_output deployment_id "$id"
          set_output result syncing
          return 10
        fi
        pause
        ;;
    esac
  done
}

create_deployment() {
  local version="$1" artifact="$2" oidc="$3" payload id status status_url message
  payload="$(jq -n \
    --argjson artifact_id "$artifact" \
    --arg pages_build_version "$version" \
    --arg oidc_token "$oidc" \
    '{artifact_id:$artifact_id, pages_build_version:$pages_build_version, oidc_token:$oidc_token}')"
  if ! api POST "${API}/pages/deployments" "$payload"; then
    log "creating deployment ${version} failed before a response"
    return 1
  fi
  if [ "$LAST_CODE" -ge 400 ]; then
    message="$(printf '%s' "$LAST_BODY" | jq -r '.message // empty' 2>/dev/null || true)"
    log "create ${version} failed: http ${LAST_CODE} ${message}"
    return 1
  fi
  status="$(printf '%s' "$LAST_BODY" | jq -r '.status // empty' 2>/dev/null || true)"
  id="$(printf '%s' "$LAST_BODY" | jq -r '.id // empty' 2>/dev/null || true)"
  status_url="$(printf '%s' "$LAST_BODY" | jq -r '.status_url // empty' 2>/dev/null || true)"
  if [ -z "$id" ] && [ -n "$status_url" ]; then
    id="${status_url##*/}"
  fi
  if [ -z "$id" ]; then
    id="$version"
  fi
  log "created deployment version ${version} id ${id} http ${LAST_CODE} status ${status:-<empty>}"
  CREATED_ID="$id"
}

watch_mode() {
  local deadline start
  start="$(now)"
  deadline=$((start + WAIT_SEC))
  while :; do
    fetch "$SHA"
    case "$KIND" in
      live)
        finish_live "$SHA"
        return 0
        ;;
      syncing)
        set_output deployment_id "$SHA"
        if [ "$(now)" -ge "$deadline" ]; then
          log "Branch deploy of ${SHA} is still syncing. A second attempt will resume it and will not cancel it."
          set_output result syncing
          return 0
        fi
        ;;
      terminal)
        log "Deployment ${SHA} is terminal. A second attempt will deploy the full artifact."
        set_output deployment_id "$SHA"
        set_output result needs_deploy
        return 0
        ;;
      denied)
        log "Cannot read the Pages deployment."
        return 1
        ;;
      missing|unknown)
        if [ $(( $(now) - start )) -ge "$ABSENT_SEC" ]; then
          log "No deployment for ${SHA} after ${ABSENT_SEC}s. A second attempt will create one."
          set_output result needs_deploy
          return 0
        fi
        ;;
    esac
    if [ "$(now)" -ge "$deadline" ]; then
      set_output result needs_deploy
      return 0
    fi
    pause
  done
}

finish_mode() {
  local deadline head version artifact oidc rc
  deadline=$(( $(now) + WAIT_SEC ))

  # Resume the deployment this run already started, then the branch-source
  # deployment (the commit SHA), then the stable retry id.
  local candidate
  for candidate in ${PAGES_DEPLOYMENT_ID:-} "$SHA" "${SHA}-retry"; do
    [ -n "$candidate" ] || continue
    fetch "$candidate"
    case "$KIND" in
      live)
        finish_live "$candidate"
        return 0
        ;;
      denied)
        log "Cannot read Pages deployment ${candidate}."
        return 1
        ;;
      syncing)
        set +e
        poll_id "$candidate" "$deadline"
        rc=$?
        set -e
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ]; then
          return "$rc"
        fi
        if [ "$rc" -eq 1 ]; then
          return 1
        fi
        # Terminal: try the next id, then deploy the full artifact if needed.
        ;;
    esac
  done

  head="$(main_head)"
  if [ -n "$head" ] && [ "$head" != "$SHA" ]; then
    log "main is ${head}, this run is ${SHA}. Not starting a deployment that would roll the site backward."
    set_output result skipped
    return 0
  fi

  artifact="$(artifact_id)"
  if [ -z "$artifact" ]; then
    log "The github-pages artifact from this run is missing, so there is nothing complete to publish."
    return 1
  fi
  case "$artifact" in
    ''|*[!0-9]*)
      log "Refusing to deploy artifact id '${artifact}'."
      return 1
      ;;
  esac
  oidc="$(oidc_token)" || return 1

  version="${SHA}-retry"
  # If that id is already a finished failure, use a fresh version so Pages
  # starts a new sync of the same full artifact instead of returning the old one.
  fetch "$version"
  if [ "$KIND" = "live" ]; then
    finish_live "$version"
    return 0
  fi
  if [ "$KIND" = "syncing" ]; then
    set +e
    poll_id "$version" "$deadline"
    rc=$?
    set -e
    return "$rc"
  fi
  if [ "$KIND" = "terminal" ]; then
    version="${SHA}-retry-${GITHUB_RUN_ID:-0}"
  fi

  if ! create_deployment "$version" "$artifact" "$oidc"; then
    return 1
  fi
  set +e
  poll_id "$CREATED_ID" "$deadline"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && [ "$version" = "${SHA}-retry" ]; then
    log "Retry id ${CREATED_ID} did not start a new sync. Trying a fresh deployment of the same artifact."
    version="${SHA}-retry-${GITHUB_RUN_ID:-0}"
    if ! create_deployment "$version" "$artifact" "$oidc"; then
      return 1
    fi
    set +e
    poll_id "$CREATED_ID" "$deadline"
    rc=$?
    set -e
  fi
  if [ "$rc" -eq 2 ]; then
    log "Deployment ${CREATED_ID} failed. The uploaded artifact was not published."
    return 1
  fi
  return "$rc"
}

main() {
  local rc=0
  set +e
  case "$MODE" in
    watch) watch_mode; rc=$? ;;
    finish) finish_mode; rc=$? ;;
    *)
      log "Unknown PAGES_MODE '${MODE}'."
      rc=1
      ;;
  esac
  exit "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
