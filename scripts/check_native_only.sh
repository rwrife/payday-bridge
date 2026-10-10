#!/usr/bin/env bash
# Native-only framework gate (reusable across the rwrife iOS fleet).
#
# Fails the build if any prohibited cross-platform/hybrid framework leaves a
# trace in the repository: Flutter, React Native, Expo, Kotlin Multiplatform,
# .NET MAUI, Unity.
#
# Usage: copy into the target repo's scripts/, chmod +x, and add a CI step
#   - name: Native-only framework gate
#     run: bash scripts/check_native_only.sh
# to BOTH the Linux package job and the macOS iOS job (right after the
# zero-network gate). No per-product renames needed — roots are repo-wide
# and the exclusions keep .git/build noise out of the scan.
#
# Checks two surfaces:
#   1. Manifest/fingerprint files anywhere in the tree (existence alone is a
#      violation).
#   2. Dependency-manifest content (package.json, .csproj, .gradle.kts ...)
#      referencing prohibited frameworks.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
report() {
  echo "::error::NATIVE-ONLY GATE FAILED: $1"
  fail=1
}

# --- 1. Fingerprint files (existence alone is a violation) ---
FP_PATTERNS=(
  "pubspec.yaml"            # Flutter / Dart
  "analysis_options.yaml"   # Dart
  "ProjectVersion.txt"      # Unity (Assets/../ProjectSettings/ProjectVersion.txt)
)
for pat in "${FP_PATTERNS[@]}"; do
  hits=$(find . \
    \( -name .git -o -name DerivedData -o -name .build -o -name node_modules -o -name '.*.build' \) -prune \
    -o -type f -name "$pat" -print || true)
  if [ -n "$hits" ]; then
    report "prohibited fingerprint file(s) found for pattern '$pat':"
    echo "$hits"
  fi
done

# Unity project directories
if [ -d "Assets" ] && [ -d "ProjectSettings" ] && [ -d "Library" ]; then
  report "Unity project directory layout detected (Assets/ + ProjectSettings/ + Library/)"
fi

# --- 2. Dependency-manifest content scans ---
scan_manifest() {
  local label="$1" pattern="$2" glob="$3"
  local hits
  hits=$(grep -RnlE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.build \
    --exclude-dir=DerivedData --include="$glob" "$pattern" . 2>/dev/null || true)
  if [ -n "$hits" ]; then
    report "$label referenced in dependency manifest(s):"
    echo "$hits"
  fi
}

scan_manifest "React Native" '"react-native"|@react-native' "package.json"
scan_manifest "Expo" '"expo"|expo-' "package.json"
scan_manifest "Flutter (dart imports)" '^import .package:flutter' "*.dart"
scan_manifest "Kotlin Multiplatform" 'kotlin\.multiplatform|org\.jetbrains\.kotlin\.multiplatform' "*.gradle*"
scan_manifest ".NET MAUI" 'Microsoft\.Maui|<UseMaui>' "*.csproj"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "Native-only gate: PASS (no Flutter/React Native/Expo/Kotlin Multiplatform/.NET MAUI/Unity traces)"
