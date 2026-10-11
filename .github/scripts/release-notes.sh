#!/usr/bin/env bash
# Writes the release notes for an App Distribution build: which build it is, then the
# "How to test" section of each pull request that went into it, so the tester knows what
# to try. Reads the pull requests (JSON from the GitHub API) on stdin. Never fails: the
# build is sent even if there is nothing to say.
set -uo pipefail

version="${VERSION:-?}"
ref="${REF_NAME:-?}"
sha="${SHA:-0000000}"

echo "Short-Circuit $version from $ref (${sha:0:7})"
echo

prs="$(cat)"
count="$(jq -e 'if type == "array" then length else 0 end' <<<"$prs" 2>/dev/null || echo 0)"
if [[ ! "$count" =~ ^[0-9]+$ || "$count" -eq 0 ]]; then
  echo "No pull request is linked to this build, so there are no testing instructions."
  exit 0
fi

for ((i = 0; i < count; i++)); do
  number="$(jq -r ".[$i].number" <<<"$prs")"
  title="$(jq -r ".[$i].title" <<<"$prs")"
  body="$(jq -r ".[$i].body // \"\"" <<<"$prs")"
  # The text under "## How to test ..." up to the next "## " heading, without HTML comments
  # (the template's hints) or leading blank lines.
  steps="$(printf '%s\n' "$body" | tr -d '\r' | sed '/<!--/,/-->/d' \
    | awk '/^## /{on=($0 ~ /^## How to test/); next} on' | awk 'NF{f=1} f')"
  echo "#$number $title"
  echo
  if [[ -n "${steps//[[:space:]]/}" ]]; then
    echo "How to test:"
    echo "$steps"
  else
    echo "No testing instructions were written in this pull request."
  fi
  echo
done
