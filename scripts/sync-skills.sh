#!/usr/bin/env bash
#
# sync-skills.sh — vendor Agent Skills from the canonical ai-skills repo into
# this Codex plugin.
#
# It fetches the source repo at a given ref, copies the selected skill folders
# into ./skills/, and records provenance in .codex-plugin/skill-source.json.
#
# It deliberately does NOT bump the plugin version in .codex-plugin/plugin.json;
# a maintainer reviews the resulting diff and bumps the version in the PR.
#
# Usage:
#   scripts/sync-skills.sh [REF]
#
# Environment variables (all optional):
#   SOURCE_REPO   GitHub "owner/name" to sync from. Default: cadence-workflow/ai-skills
#   REF           Git ref (tag/branch/sha) to sync. Default: latest release tag,
#                 falling back to the repo's default branch. CLI arg overrides this.
#   SKILLS        Space-separated skill folder names to vendor.
#                 Default: cadence-developer
#
# Requirements: git, rsync, and (for default-ref resolution) curl + a JSON-capable
# environment. GITHUB_TOKEN is used for API calls when present (raises rate limits).

set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-cadence-workflow/ai-skills}"
SKILLS="${SKILLS:-cadence-developer}"
REF="${1:-${REF:-}}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

log() { printf '\033[1;34m[sync-skills]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[sync-skills] error:\033[0m %s\n' "$*" >&2; exit 1; }

api() {
  # GET a GitHub API path, with auth if GITHUB_TOKEN is set.
  local path="$1"
  local -a auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL "${auth[@]}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/${path}"
}

resolve_latest_ref() {
  # Prefer the latest published release tag; otherwise the default branch.
  local tag
  tag="$(api "repos/${SOURCE_REPO}/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" || true
  if [[ -n "$tag" ]]; then
    printf '%s' "$tag"
    return 0
  fi
  local branch
  branch="$(api "repos/${SOURCE_REPO}" 2>/dev/null \
    | grep -m1 '"default_branch"' \
    | sed -E 's/.*"default_branch"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" || true
  printf '%s' "${branch:-main}"
}

command -v git >/dev/null 2>&1 || die "git is required"
command -v rsync >/dev/null 2>&1 || die "rsync is required"

if [[ -z "$REF" ]]; then
  log "No ref given; resolving latest release for ${SOURCE_REPO}..."
  REF="$(resolve_latest_ref)"
fi
log "Source repo: ${SOURCE_REPO}"
log "Ref:         ${REF}"
log "Skills:      ${SKILLS}"

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

clone_dir="${workdir}/src"
log "Cloning ${SOURCE_REPO}@${REF}..."
git clone --quiet --depth 1 --branch "$REF" \
  "https://github.com/${SOURCE_REPO}.git" "$clone_dir" 2>/dev/null \
  || {
    # --branch doesn't accept arbitrary commit SHAs; fall back to full fetch.
    log "Shallow branch clone failed; trying full clone + checkout..."
    git clone --quiet "https://github.com/${SOURCE_REPO}.git" "$clone_dir"
    git -C "$clone_dir" checkout --quiet "$REF"
  }

resolved_sha="$(git -C "$clone_dir" rev-parse HEAD)"
log "Resolved commit: ${resolved_sha}"

mkdir -p skills
for skill in $SKILLS; do
  srcdir="${clone_dir}/skills/${skill}"
  [[ -d "$srcdir" ]] || die "skill '${skill}' not found in ${SOURCE_REPO}@${REF}"
  log "Vendoring skill: ${skill}"
  rsync -a --delete \
    --exclude '.DS_Store' \
    --exclude '.git' \
    "${srcdir}/" "skills/${skill}/"
done

synced_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Build a JSON array of skill names, e.g. ["a", "b"].
skills_json="$(
  first=1
  printf '['
  for skill in $SKILLS; do
    [[ $first -eq 1 ]] || printf ', '
    printf '"%s"' "$skill"
    first=0
  done
  printf ']'
)"

mkdir -p .codex-plugin
cat > .codex-plugin/skill-source.json <<EOF
{
  "sourceRepo": "${SOURCE_REPO}",
  "ref": "${REF}",
  "commit": "${resolved_sha}",
  "skills": ${skills_json},
  "syncedAt": "${synced_at}"
}
EOF

log "Wrote .codex-plugin/skill-source.json"
log "Done. Review the diff and bump the plugin version in .codex-plugin/plugin.json before merging."
