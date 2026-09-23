#!/usr/bin/env bash
# Builds the Film Lab renderer from the app's own processing sources plus the
# tool-only sources, in Swift 5 mode with complete concurrency checking.
# Usage: tools/film-lab/build.sh [--strict] [--force]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out_dir="$here/.build"
binary="$out_dir/film-lab-renderer"

strict=0
force=0
for argument in "$@"; do
  case "$argument" in
    --strict) strict=1 ;;
    --force) force=1 ;;
    *) echo "usage: $0 [--strict] [--force]" >&2; exit 64 ;;
  esac
done

# The exact shared closure: the renderer, recipe model and their
# dependencies. No UIKit, capture, storage or VideoProcessor.
shared=(
  "$repo/Aperture/Processing/FilmProcessor.swift"
  "$repo/Aperture/Processing/FilmProcessor+Effects.swift"
  "$repo/Aperture/Processing/FilmProcessor+Overlays.swift"
  "$repo/Aperture/Processing/FilmProcessor+Rasterization.swift"
  "$repo/Aperture/Processing/FilmProcessingTypes.swift"
  "$repo/Aperture/Processing/FilmColorModel.swift"
  "$repo/Aperture/Processing/FilmResponse.swift"
  "$repo/Aperture/Processing/FilmStage.swift"
  "$repo/Aperture/Models/FilmRecipe.swift"
  "$repo/Aperture/Models/DateStamp.swift"
  "$repo/Aperture/Models/SeededRandomNumberGenerator.swift"
  "$repo/Aperture/Models/AppSettings.swift"
)
tool=("$here"/Sources/*.swift)

if [[ $force -eq 0 && $strict -eq 0 && -x "$binary" ]]; then
  stale=0
  for source in "${shared[@]}" "${tool[@]}" "$here/build.sh"; do
    if [[ "$source" -nt "$binary" ]]; then stale=1; break; fi
  done
  if [[ $stale -eq 0 ]]; then exit 0; fi
fi

mkdir -p "$out_dir"
flags=(-swift-version 5 -strict-concurrency=complete -O -target "$(uname -m)-apple-macosx14.0")
if [[ $strict -eq 1 ]]; then flags+=(-warnings-as-errors); fi

echo "Building film-lab-renderer (${#shared[@]} shared + ${#tool[@]} tool sources)…" >&2
xcrun swiftc "${flags[@]}" -module-name FilmLabRenderer "${shared[@]}" "${tool[@]}" \
  -o "$binary.tmp"
mv -f "$binary.tmp" "$binary"
echo "$binary" >&2
