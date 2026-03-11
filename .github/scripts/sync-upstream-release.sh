#!/usr/bin/env bash
set -euo pipefail

state_file=".github/upstream-release-state.json"
source_dir=".tmp-upstream-release-source"

cleanup() {
  rm -rf "${source_dir}"
}

trap cleanup EXIT

latest_tag="$(
  curl -fsSL \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))"
)"

if [[ -z "${latest_tag}" ]]; then
  echo "No upstream release tag found."
  exit 0
fi

recorded_tag=""
if [[ -f "${state_file}" ]]; then
  recorded_tag="$(
    python3 - "${state_file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
print(data.get("latest_release_tag", ""))
PY
  )"
fi

if git ls-remote --exit-code --tags origin "refs/tags/${latest_tag}" >/dev/null 2>&1; then
  echo "Latest upstream release already mirrored to fork: ${latest_tag}"
  exit 0
fi

if [[ "${recorded_tag}" == "${latest_tag}" ]]; then
  echo "Latest upstream release already deployed and recorded: ${latest_tag}"
  exit 0
fi

echo "Processing new upstream release: ${latest_tag}"

if [[ -n "${SYNC_PAT:-}" ]]; then
  git remote add upstream https://github.com/router-for-me/CLIProxyAPI.git || true
  git remote add origin-pat "https://x-access-token:${SYNC_PAT}@github.com/${GITHUB_REPOSITORY}.git" || true
  git remote set-url origin-pat "https://x-access-token:${SYNC_PAT}@github.com/${GITHUB_REPOSITORY}.git"

  git fetch upstream --tags --prune
  git fetch upstream "refs/tags/${latest_tag}:refs/tags/${latest_tag}"
  git fetch upstream "refs/heads/main:refs/remotes/upstream/main"
  git push origin-pat "refs/tags/${latest_tag}:refs/tags/${latest_tag}"
  git push origin-pat "refs/remotes/upstream/main:refs/heads/upstream-main"
else
  echo "SYNC_PAT is not configured. Skipping fork tag and branch mirroring."
fi

git clone --depth 1 --branch "${latest_tag}" https://github.com/router-for-me/CLIProxyAPI.git "${source_dir}"

gcloud auth list --filter=status:ACTIVE --format="value(account)"
gcloud run deploy "${SERVICE}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --platform managed \
  --port 8317 \
  --source "${source_dir}" \
  --quiet

gcloud run services describe "${SERVICE}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --platform managed \
  --format="value(status.latestReadyRevisionName)"

export LATEST_TAG="${latest_tag}"

python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

path = Path(".github/upstream-release-state.json")
path.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "latest_release_tag": os.environ["LATEST_TAG"],
    "source_repository": "router-for-me/CLIProxyAPI",
    "updated_at": datetime.now(timezone.utc).isoformat(),
}
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "${state_file}"

if git diff --cached --quiet; then
  echo "No release state changes to commit."
  exit 0
fi

git commit -m "chore: record upstream release ${latest_tag}"
git push origin HEAD:main
