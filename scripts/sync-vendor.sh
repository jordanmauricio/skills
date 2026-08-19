#!/usr/bin/env bash
# Sync pinned upstream skills declared in vendor.yaml into packs/*/skills/vendor/.
#
# THE FORK RULE: packs/*/skills/vendor/ is machine-written and wiped on every run.
# Never hand-edit it. To change a vendored skill, move it to skills/mine/, rename
# it, and drop its line from vendor.yaml.
#
# Depends only on git, awk and python3 (no yq, no PyYAML).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO/vendor.yaml"
TMP="$REPO/.tmp/vendor"
cd "$REPO"

[ -f "$MANIFEST" ] || { echo "error: no vendor.yaml at $MANIFEST" >&2; exit 1; }

# ---------------------------------------------------------------- parse manifest
# Emits: kind \t owner/repo \t ref \t pack \t path
parse() {
  awk -F': *' '
    /^  - from:/  { from=$2; mode=""; next }
    /^    ref:/   { ref=$2;  next }
    /^    pack:/  { pack=$2; next }
    /^    skills:/ { mode="skill"; next }
    /^    agents:/ { mode="agent"; next }
    /^      - /   {
      if (mode == "") next
      path=$0; sub(/^      - /, "", path)
      printf "%s\t%s\t%s\t%s\t%s\n", mode, from, ref, pack, path
    }
  ' "$MANIFEST"
}

ENTRIES="$(parse)"
[ -n "$ENTRIES" ] || { echo "error: vendor.yaml parsed to nothing — check indentation" >&2; exit 1; }

# ------------------------------------------------------------------- clean slate
# vendor/ is fully machine-owned, so wipe it. agents/ may hold our own later, so
# only remove what a previous run recorded.
for pack in "$REPO"/packs/*/; do
  rm -rf "${pack}skills/vendor"
  mkdir -p "${pack}skills/vendor/_licenses"
  if [ -f "${pack}agents/.vendored" ]; then
    while IFS= read -r f; do [ -n "$f" ] && rm -f "${pack}agents/$f"; done < "${pack}agents/.vendored"
  fi
  : > "${pack}agents/.vendored"
done

rm -rf "$TMP"; mkdir -p "$TMP"

# ------------------------------------------------------------------ clone + copy
# Memoised on disk, not in a shell array: this runs inside $( ) so any variable
# state would be lost with the subshell.
clone_once() {
  local from="$1" ref="$2" dest="$TMP/${from//\//__}@$ref"
  if [ ! -d "$dest/.git" ]; then
    git clone -q --depth 1 --branch "$ref" "https://github.com/$from.git" "$dest" 2>/dev/null \
      || { git clone -q "https://github.com/$from.git" "$dest" && git -C "$dest" checkout -q "$ref"; }
  fi
  echo "$dest"
}

skills=0; agents=0
while IFS=$'\t' read -r kind from ref pack path; do
  [ -n "${kind:-}" ] || continue
  src_root="$(clone_once "$from" "$ref")"
  sha="$(git -C "$src_root" rev-parse --short HEAD)"
  owner="${from%%/*}"; repo="${from##*/}"

  # upstream licence, once per source
  lic="$REPO/packs/$pack/skills/vendor/_licenses/$owner-$repo.LICENSE"
  if [ ! -f "$lic" ]; then
    for cand in LICENSE LICENSE.md LICENSE.txt; do
      [ -f "$src_root/$cand" ] && { cp "$src_root/$cand" "$lic"; break; }
    done
  fi

  if [ "$kind" = "skill" ]; then
    name="$(basename "$path")"
    dest="$REPO/packs/$pack/skills/vendor/$name"
    [ -d "$src_root/$path" ] || { echo "error: $from@$ref has no $path" >&2; exit 1; }
    [ -e "$dest" ] && { echo "error: duplicate skill name '$name' — names are flat and global" >&2; exit 1; }
    cp -R "$src_root/$path" "$dest"
    printf 'source: %s\nref: %s\ncommit: %s\npath: %s\n' "$from" "$ref" "$sha" "$path" > "$dest/.provenance"
    skills=$((skills+1))
  else
    name="$(basename "$path")"
    cp "$src_root/$path" "$REPO/packs/$pack/agents/$name"
    echo "$name" >> "$REPO/packs/$pack/agents/.vendored"
    agents=$((agents+1))
  fi
done <<< "$ENTRIES"

rm -rf "$TMP"

# ----------------------------------------------- regenerate plugin.json skill list
python3 - "$REPO" <<'PY'
import json, os, sys, pathlib
repo = pathlib.Path(sys.argv[1])
for pack in sorted((repo / "packs").iterdir()):
    manifest = pack / ".claude-plugin" / "plugin.json"
    if not manifest.exists():
        continue
    found = sorted(
        "./" + str(p.parent.relative_to(pack))
        for p in (pack / "skills").rglob("SKILL.md")
    )
    data = json.loads(manifest.read_text())
    data["skills"] = found
    manifest.write_text(json.dumps(data, indent=2) + "\n")
    print(f"{pack.name}: {len(found)} skills in plugin.json")
PY

# ------------------------------------------------------------- depth guard (hard)
bad=0
while IFS= read -r f; do
  # directory depth, excluding the SKILL.md filename itself
  depth="$(awk -F/ '{print NF-1}' <<< "$f")"
  if [ "$depth" -gt 5 ]; then echo "DEPTH: $f (dir depth $depth, limit 5)" >&2; bad=1; fi
done < <(cd "$REPO" && find packs -name SKILL.md | sed 's|^\./||')
if [ "$bad" = 1 ]; then
  echo "error: skills deeper than 5 path segments are silently skipped by npx skills" >&2
  exit 1
fi

echo "synced $skills skills, $agents agents"
