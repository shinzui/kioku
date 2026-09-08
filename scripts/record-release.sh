#!/usr/bin/env bash
# Record the mori Project release fact for shinzui/kioku from an observed tag.
#
# Called once per release by the `release` automation (automation/release.dhall).
# That config's `refRegexes` already restricts the trigger to a `v<version>` tag,
# so this script does not exist to filter: it exists to do the two things a
# reaction cannot express -- strip the `v` prefix and read the tag's own
# creation time.
set -euo pipefail

tag=${1:?usage: record-release.sh TAG}

# The selector guarantees this shape, so a mismatch is a bug in the selector or
# a hand-run with the wrong argument. Fail loudly rather than recording a
# version that breaks the convention below.
if [[ ! $tag =~ ^v([0-9]+(\.[0-9]+)*)$ ]]; then
  echo "record-release: $tag is not a kioku release tag" >&2
  exit 1
fi

# Mori keeps one release fact per project, and kioku's project version is the
# version its five packages share, recorded without the tag prefix -- `0.5.2.0`,
# not `v0.5.2.0`. That matches shinzui/baikai, shinzui/shikumi and shinzui/keiro,
# whose facts are also bare versions. Versions are opaque to mori -- it never
# parses or compares them -- so nothing but this line enforces that.
version=${BASH_REMATCH[1]}

# The tag's own creation time, not the observation time. The two agree when the
# daemon is healthy, but ingest can lag a tag by months -- baikai's did -- and
# the release fact is immutable, so a wrong first write cannot be corrected
# later. Fall back to mori's default (now) only when git has nothing to offer.
released_at=$(TZ=UTC git for-each-ref \
  --format='%(creatordate:format-local:%Y-%m-%dT%H:%M:%SZ)' \
  "refs/tags/${tag}")

if [[ -n $released_at ]]; then
  exec mori registry release record shinzui/kioku "$version" \
    --released-at "$released_at" \
    --source "git-tag:${tag}"
fi

exec mori registry release record shinzui/kioku "$version" \
  --source "git-tag:${tag}"
