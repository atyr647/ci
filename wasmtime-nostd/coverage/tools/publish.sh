#!/bin/bash
# publish.sh <directory> <destination inside the branch>: copies a directory of results to the branch `nostd-coverage-results` (the older `coverage-results` branch got a Git-for-Windows tree pushed by accident when the source directory did not exist; do not use it) so they can be read without downloading artifacts.
# env: GITHUB_TOKEN, GITHUB_REPOSITORY (set by the workflow)
set +e
[ -d "$1" ] || { echo "publish: $1 does not exist, nothing published"; exit 0; }
SRC=$(cd "$1" && pwd); [ -n "$SRC" ] && [ "$SRC" != "/" ] || { echo "publish: bad source"; exit 0; }
DEST=$2; BR=nostd-coverage-results
D=$(mktemp -d); cd "$D"
git init -q; git config user.name atyr647; git config user.email atyr647@users.noreply.github.com
git remote add o "https://x-access-token:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY.git"
for i in 1 2 3 4 5 6 7 8; do
  if git fetch -q o $BR 2>/dev/null; then git checkout -q -B res FETCH_HEAD; else git checkout -q --orphan res; fi
  mkdir -p "$DEST"; cp -r "$SRC"/. "$DEST"/; git add -A "$DEST"; git commit -qm "results $DEST"
  if git push -q o res:$BR; then echo "published $DEST"; exit 0; fi
  sleep $((RANDOM % 6 + 2))
done
echo "publish failed"
