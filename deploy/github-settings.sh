#!/usr/bin/env bash
# Sets Steady's GitHub rulesets and the signing environment's branches, as docs/DEPLOY.md
# ("Branches") describes. Run on your own computer with the GitHub CLI signed in as a repository
# admin (gh auth login). Safe to run again: it updates what exists and adds what's missing.
#   deploy/github-settings.sh               apply
#   deploy/github-settings.sh --retire-v1   also drop the old v1 branch's ruleset and its access
#                                           to the signing environment (once vps1 follows test)
#
# What it sets:
#   (repository)      merged branches are kept: GitHub no longer deletes working or test after
#                     a merge
#   Main, Test        only through a pull request with CI green; never deleted or force-pushed
#   Working           never deleted or force-pushed
#   CI-built branches web-dist, web-dist-*, previews: written only by GitHub Actions, so not even
#                     an owner's token can swap a web build (deploy/release.sh relies on this)
#   signing           the environment holding the store and test-build keys: main and test only
# The release tags' ruleset (v*, web-v*: admins only, never moved or deleted) is left as it is.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
REPO="${STEADY_REPO_SLUG:-OpenWorksIT/steady}"
RETIRE_V1=no
[ "${1:-}" = "--retire-v1" ] && RETIRE_V1=yes

command -v gh >/dev/null || { echo "Install the GitHub CLI first (gh), then: gh auth login" >&2; exit 1; }
[ "$(gh api "repos/$REPO" --jq .permissions.admin)" = true ] || { echo "Your GitHub account isn't an admin of $REPO." >&2; exit 1; }

# GitHub Actions, as an actor in rulesets and status checks
ACTIONS=15368
CHECKS='[{"context":"server","integration_id":15368},{"context":"server-live","integration_id":15368},{"context":"e2e","integration_id":15368},{"context":"pusher","integration_id":15368},{"context":"app","integration_id":15368},{"context":"android","integration_id":15368}]'
PR_RULE='{"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false,"allowed_merge_methods":["merge","squash","rebase"]}}'
CHECKS_RULE="{\"type\":\"required_status_checks\",\"parameters\":{\"strict_required_status_checks_policy\":false,\"do_not_enforce_on_create\":false,\"required_status_checks\":$CHECKS}}"

# upsert NAME JSON: updates the ruleset with that name, or creates it
upsert() {
  local id
  id="$(gh api "repos/$REPO/rulesets?includes_parents=false" --jq ".[] | select(.name == \"$1\") | .id" | head -1)"
  if [ -n "$id" ]; then
    printf '%s' "$2" | gh api -X PUT "repos/$REPO/rulesets/$id" --input - --jq '"  updated: \(.name)"'
  else
    printf '%s' "$2" | gh api -X POST "repos/$REPO/rulesets" --input - --jq '"  created: \(.name)"'
  fi
}

# branch_ruleset NAME INCLUDE-JSON RULES-JSON [BYPASS-JSON]
branch_ruleset() {
  upsert "$1" "{\"name\":\"$1\",\"target\":\"branch\",\"enforcement\":\"active\",\"conditions\":{\"ref_name\":{\"include\":$2,\"exclude\":[]}},\"rules\":$3,\"bypass_actors\":${4:-[]}}"
}

# merging working into test, or test into main, must never delete the branch it came from
gh api -X PATCH "repos/$REPO" -F delete_branch_on_merge=false --jq '"Branches stay after a merge: \(.delete_branch_on_merge | not)"'

echo "Rulesets on $REPO:"
branch_ruleset "Main" '["~DEFAULT_BRANCH"]' "[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,$CHECKS_RULE]"
branch_ruleset "Test" '["refs/heads/test"]' "[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,$CHECKS_RULE]"
branch_ruleset "Working" '["refs/heads/working"]' '[{"type":"deletion"},{"type":"non_fast_forward"}]'
branch_ruleset "CI-built branches" '["refs/heads/web-dist","refs/heads/web-dist-*","refs/heads/previews"]' \
  '[{"type":"creation"},{"type":"update"},{"type":"deletion"},{"type":"non_fast_forward"}]' \
  "[{\"actor_id\":$ACTIONS,\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]"

echo "The signing environment:"
env_url="repos/$REPO/environments/signing"
if [ "$(gh api "$env_url" --jq '.deployment_branch_policy.custom_branch_policies // false')" != true ]; then
  # only the branch policy is sent; the environment's secrets and other settings stay as they are
  gh api -X PUT "$env_url" --input - --jq '"  only chosen branches may use it now"' <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
fi
have="$(gh api "$env_url/deployment-branch-policies" --jq '.branch_policies[] | "\(.id) \(.type // "branch") \(.name)"')"
for b in main test; do
  if ! grep -q " branch $b\$" <<<"$have"; then
    gh api -X POST "$env_url/deployment-branch-policies" -f name="$b" -f type=branch --jq '"  added: \(.name)"'
  else
    echo "  already allowed: $b"
  fi
done
while read -r id type name; do
  [ -n "${id:-}" ] || continue
  case "$name" in
    main|test) ;;
    v1) if [ "$RETIRE_V1" = yes ]; then gh api -X DELETE "$env_url/deployment-branch-policies/$id" >/dev/null && echo "  removed: v1"; else echo "  still allowed: v1 (--retire-v1 removes it once vps1 follows test)"; fi ;;
    *) echo "  also allowed: $name ($type): remove it in Settings > Environments > signing if it shouldn't be" ;;
  esac
done <<<"$have"

if [ "$RETIRE_V1" = yes ]; then
  id="$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "v1") | .id' | head -1)"
  [ -n "$id" ] && gh api -X DELETE "repos/$REPO/rulesets/$id" >/dev/null && echo "Removed the v1 ruleset (the v1 branch itself stays until you delete it)."
fi

cat <<EOF

Done. Check: the next "Test builds" run must still update web-dist (Actions tab, green, and
web-dist's newest commit reads "Web app built from <that commit>"). If it fails at "publish the
web app", GitHub Actions isn't allowed past the "CI-built branches" ruleset: Settings > Rules >
Rulesets > CI-built branches > Bypass list, add GitHub Actions; until then release.sh refuses.
EOF
