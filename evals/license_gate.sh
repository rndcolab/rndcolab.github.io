#!/usr/bin/env bash
# license_gate.sh — enforce ADR-018: AuraGIS is proprietary by default.
#
# Fails if any manifest self-declares an OSI licence, if a crate or npm package
# could reach a public registry, or if a LICENSE carries permissive text.
#
# This gate exists because the default drifted once already: four manifests
# declared Apache-2.0 and nobody intended it. Policy that is not mechanical
# is a memo.
#
# Usage: tools/license_gate.sh [repo-root]   (default: .)
set -uo pipefail
ROOT="${1:-.}"
fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }
bad() { say "FAIL" "$1"; fail=1; }

# Identifiers we must never apply to our OWN code. Dependencies declaring
# these are fine and expected — this checks self-declaration only.
OSI='Apache-2\.0|\bMIT\b|BSD-[23]-Clause|MPL-2\.0|GPL-[23]|LGPL-[23]|ISC|Unlicense'

# node_modules and target are enormous on a synced drive: prune, don't filter.
find_pruned() {
  find "$ROOT" \( -name node_modules -o -name target -o -name .git -o -name dist \) -prune \
       -o -name "$1" -print 2>/dev/null
}

echo "ADR-018 licence gate — $ROOT"

while IFS= read -r m; do
  [ -z "$m" ] && continue
  grep -Eq '^[[:space:]]*license[[:space:]]*=[[:space:]]*"('"$OSI"')"' "$m" \
    && bad "$m declares an OSI licence for our own code"
  if grep -q '^\[package\]' "$m"; then
    grep -Eq '^[[:space:]]*publish[[:space:]]*=[[:space:]]*false' "$m" \
      || bad "$m has [package] but no 'publish = false'"
    # ADR-018 §2: `license` is *replaced by* `license-file`, not merely
    # emptied. Silence is not a proprietary declaration — a manifest that
    # says nothing reads as unlicensed-by-oversight, which is the state
    # three of these were in when the gate first passed them clean.
    grep -Eq '^[[:space:]]*license-file[[:space:]]*=' "$m" \
      || bad "$m has [package] but no 'license-file' (ADR-018 §2)"
  fi
done < <(find_pruned Cargo.toml)

while IFS= read -r m; do
  [ -z "$m" ] && continue
  grep -Eq 'license[[:space:]]*=.*("|'"'"')('"$OSI"')' "$m" \
    && bad "$m declares an OSI licence for our own code"
  if grep -q '^\[project\]' "$m"; then
    grep -Eq '^[[:space:]]*license[[:space:]]*=' "$m" \
      || bad "$m has [project] but declares no licence (ADR-018 §2)"
  fi
done < <(find_pruned pyproject.toml)

while IFS= read -r m; do
  [ -z "$m" ] && continue
  grep -q '"private"[[:space:]]*:[[:space:]]*true' "$m" \
    || bad "$m is missing \"private\": true"
  grep -Eq '"license"[[:space:]]*:[[:space:]]*"('"$OSI"')"' "$m" \
    && bad "$m declares an OSI licence for our own code"
  grep -Eq '"license"[[:space:]]*:' "$m" \
    || bad "$m declares no \"license\" (ADR-018 §2; use \"UNLICENSED\")"
done < <(find_pruned package.json)

if [ -f "$ROOT/LICENSE" ]; then
  grep -Eq 'Apache License|MIT License|BSD 3-Clause|GNU GENERAL PUBLIC' "$ROOT/LICENSE" \
    && bad "LICENSE carries permissive/copyleft text — ADR-018 requires a rights reservation"
else
  bad "no LICENSE at repo root"
fi

if [ -d "$ROOT/.github/workflows" ]; then
  while IFS= read -r w; do
    [ -z "$w" ] && continue
    # maturin is the build backend for BOTH Python packages, so `maturin
    # publish`/`maturin upload` is the single most likely route to an
    # accidental PyPI release — and it was the one command this pattern
    # could not see. ADR-018's whole argument is that the decision stops
    # being reversible at the first publish.
    #
    # **Whole-line comments are stripped before the grep (2026-09-27).** The
    # distinction is use versus mention — the same one that governs ADR-015's
    # `.aura` grep and the citation check's `_HISTORICAL` exclusion. A workflow
    # that *names* `npm publish` in a comment explaining this very gate is not a
    # workflow that runs it, and on this gate's first real run in `auragis` that
    # is exactly what it caught: a comment I had just written describing what
    # check 2 looks for. A false positive, reported as one.
    #
    # Only whole-line comments go. A trailing comment cannot launder a real
    # command, so `npm publish  # disabled` still fails, which is correct: the
    # line still runs.
    sed 's/^[[:space:]]*#.*$//' "$w" \
      | grep -Eq 'cargo publish|twine upload|npm publish|pypa/gh-action-pypi|maturin publish|maturin upload' \
      && bad "$w publishes to a public registry"
  done < <(find "$ROOT/.github/workflows" \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null)
fi

[ "$fail" -eq 0 ] && say "ok" "clean — nothing declares or exposes our code as open source"
exit "$fail"
