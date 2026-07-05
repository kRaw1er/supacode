#!/usr/bin/env bash
set -euo pipefail

# Builds the prebuilt static C xcframework of tree-sitter grammars consumed by the
# diff viewer's syntax highlighter. Mirrors scripts/build-ghostty.sh: a
# `--print-fingerprint` early-exit + a fingerprint short-circuit so the .foreignBuild
# target (Project.swift) only rebuilds when the lock, this script, or mise.toml change.
#
# The tree-sitter *runtime* is NOT compiled here — SwiftTreeSitter's `TreeSitter` SPM
# module already links it. Grammar `parser.c`/`scanner.c` are self-contained (each
# exports `tree_sitter_<symbol>()` returning a static TSLanguage) so this xcframework
# carries only the grammar objects. Its module header forward-declares `TSLanguage` as
# an opaque struct, so `tree_sitter_swift()` imports into Swift as `OpaquePointer` —
# exactly what `SwiftTreeSitter.Language(_:)` accepts — with zero header/type coupling.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"

lock_path="${srcroot}/scripts/treesitter-grammars.lock"
mise_path="${srcroot}/mise.toml"
build_root="${srcroot}/.build/treesitter"
src_root="${build_root}/src"
obj_root="${build_root}/obj"
headers_dir="${build_root}/Headers"
xcframework_path="${build_root}/TreeSitterGrammars.xcframework"
fat_lib="${build_root}/libTreeSitterGrammars.a"
fingerprint_path="${build_root}/fingerprint"
provenance_path="${build_root}/provenance"
queries_dir="${srcroot}/supacode/Resources/TreeSitterQueries"

deployment_target="26.0"
archs=(arm64 x86_64)

print_fingerprint() {
  {
    shasum -a 256 "${lock_path}" | awk '{print $1}'
    shasum -a 256 "${script_path}" | awk '{print $1}'
    shasum -a 256 "${mise_path}" | awk '{print $1}'
  } | shasum -a 256 | awk '{print $1}'
}

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

# --- Read the lock into parallel arrays (bash 3.2: no associative arrays). -------
# Parsed up front (before the short-circuit) so the provenance stamp and the
# artifact validation can key off the locked symbol/query set.
keys=(); repos=(); shas=(); subdirs=(); symbols=()
while IFS=$'\t' read -r key repo sha subdir symbol || [ -n "${key}" ]; do
  case "${key}" in ""|\#*) continue ;; esac
  keys+=("${key}"); repos+=("${repo}"); shas+=("${sha}"); subdirs+=("${subdir}"); symbols+=("${symbol}")
done < "${lock_path}"
count="${#keys[@]}"

# Provenance stamp: the full contract the built artifact must satisfy — the grammar
# count, a hash of the lock's DATA rows only (comments/blank excluded, so the value
# is stable when committed back into this lock's header comment), and the sorted
# exported symbols. Written next to the artifact after a successful build and
# re-checked by the short-circuit, so a partial/stale `.build/treesitter` (some
# grammars missing) can never be treated as up to date.
compute_provenance() {
  local data_sha sorted_symbols
  data_sha="$(grep -vE '^[[:space:]]*(#|$)' "${lock_path}" | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')"
  sorted_symbols="$(printf '%s\n' "${symbols[@]}" | LC_ALL=C sort | paste -sd, -)"
  printf 'grammars=%s data=%s symbols=%s\n' "${count}" "${data_sha}" "${sorted_symbols}"
}

# CI/tooling hook: print the expected provenance so a stale gitignored artifact can
# be diffed against the value committed in the lock header comment.
if [ "${1:-}" = "--print-provenance" ]; then
  compute_provenance
  exit 0
fi

# Fail loudly (non-zero, offending grammar named) if the built fat lib is missing
# any locked symbol or any locked grammar's bundled highlights.scm. Shared by the
# post-build step and the short-circuit, so neither the build nor the up-to-date
# fast path can mask a partial artifact that would degrade a diff to plain text.
validate_artifact() {
  local i sym key exported
  [ -f "${fat_lib}" ] || { echo "error: missing ${fat_lib}" >&2; return 1; }
  exported="$(nm -gU "${fat_lib}" 2>/dev/null || true)"
  for ((i = 0; i < count; i++)); do
    sym="${symbols[$i]}"; key="${keys[$i]}"
    if ! printf '%s\n' "${exported}" | grep -q "_tree_sitter_${sym}$"; then
      echo "error: ${key}: fat lib does not export _tree_sitter_${sym} (stale/partial grammars build)" >&2
      return 1
    fi
    if [ ! -f "${queries_dir}/${key}/highlights.scm" ]; then
      echo "error: ${key}: missing ${queries_dir}/${key}/highlights.scm (query not copied)" >&2
      return 1
    fi
  done
}

# Pin a stable Xcode for `clang`/`libtool`/`xcodebuild` (matches the ghostty build's
# selector so both binaries agree on the toolchain / SDK).
if [ -x "${script_dir}/select-developer-dir.sh" ]; then
  DEVELOPER_DIR="$("${script_dir}/select-developer-dir.sh")"
  export DEVELOPER_DIR
fi

fingerprint="$(print_fingerprint)"
provenance="$(compute_provenance)"
if [ -f "${fingerprint_path}" ] &&
  [ -d "${xcframework_path}" ] &&
  [ -d "${queries_dir}" ] &&
  [ -f "${provenance_path}" ] &&
  [ "$(cat "${fingerprint_path}")" = "${fingerprint}" ] &&
  [ "$(cat "${provenance_path}")" = "${provenance}" ] &&
  validate_artifact; then
  exit 0
fi

fetch_grammar() { # key repo sha
  local key="$1" repo="$2" sha="$3" dest="${src_root}/$1"
  if [ -f "${dest}/.sha" ] && [ "$(cat "${dest}/.sha")" = "${sha}" ]; then
    return 0
  fi
  rm -rf "${dest}"; mkdir -p "${dest}"
  (
    cd "${dest}"
    git init -q
    git remote add origin "${repo}"
    git fetch -q --depth 1 origin "${sha}"
    git checkout -q FETCH_HEAD
  )
  printf '%s\n' "${sha}" > "${dest}/.sha"
}

# Compile one grammar's parser.c (+ optional scanner.{c,cc,cpp}) for one arch.
compile_grammar() { # key subdir arch
  local key="$1" subdir="$2" arch="$3"
  local checkout="${src_root}/${key}"
  local gram="${checkout}"
  [ "${subdir}" != "." ] && gram="${checkout}/${subdir}"
  local src="${gram}/src"
  local out="${obj_root}/${arch}"
  mkdir -p "${out}"

  local includes=(-I "${src}")
  [ -d "${checkout}/common" ] && includes+=(-I "${checkout}/common")
  [ -d "${gram}/common" ] && includes+=(-I "${gram}/common")

  local common_flags=(-c -O2 -fPIC -arch "${arch}" -mmacosx-version-min="${deployment_target}")

  if [ ! -f "${src}/parser.c" ]; then
    echo "error: ${key}: missing ${src}/parser.c at pinned sha" >&2
    exit 1
  fi
  clang "${common_flags[@]}" -std=c11 "${includes[@]}" "${src}/parser.c" -o "${out}/${key}_parser.o"

  local scanner
  for scanner in "${src}/scanner.c" "${src}/scanner.cc" "${src}/scanner.cpp"; do
    [ -f "${scanner}" ] || continue
    case "${scanner}" in
      *.c) clang "${common_flags[@]}" -std=c11 "${includes[@]}" "${scanner}" -o "${out}/${key}_scanner.o" ;;
      *) clang++ "${common_flags[@]}" -std=c++14 "${includes[@]}" "${scanner}" -o "${out}/${key}_scanner.o" ;;
    esac
    break
  done
}

copy_queries() { # key subdir
  local key="$1" subdir="$2"
  local checkout="${src_root}/${key}"
  local gram="${checkout}"
  [ "${subdir}" != "." ] && gram="${checkout}/${subdir}"
  local scm=""
  local candidate
  for candidate in "${gram}/queries/highlights.scm" "${checkout}/queries/highlights.scm"; do
    if [ -f "${candidate}" ]; then scm="${candidate}"; break; fi
  done
  [ -n "${scm}" ] || return 0
  mkdir -p "${queries_dir}/${key}"
  cp "${scm}" "${queries_dir}/${key}/highlights.scm"
}

rm -rf "${obj_root}" "${headers_dir}" "${xcframework_path}"
mkdir -p "${obj_root}" "${headers_dir}" "${queries_dir}"

# --- Fetch + compile every grammar for every arch. -------------------------------
for ((i = 0; i < count; i++)); do
  fetch_grammar "${keys[$i]}" "${repos[$i]}" "${shas[$i]}"
  for arch in "${archs[@]}"; do
    compile_grammar "${keys[$i]}" "${subdirs[$i]}" "${arch}"
  done
  copy_queries "${keys[$i]}" "${subdirs[$i]}"
done

# --- Per-arch static libs, then a single fat lib. --------------------------------
lib_args=()
for arch in "${archs[@]}"; do
  libtool -static -o "${build_root}/libTreeSitterGrammars-${arch}.a" "${obj_root}/${arch}"/*.o
  lib_args+=("${build_root}/libTreeSitterGrammars-${arch}.a")
done
lipo -create "${lib_args[@]}" -output "${fat_lib}"

# Build-time validation (fail loudly, never mask a partial artifact): every locked
# symbol must be exported by the fat lib and every locked grammar must have copied
# its highlights.scm — the two ways a stale/partial build silently degrades a diff
# to plain text (root cause of "highlighting doesn't work").
validate_artifact

# --- Module header (forward-declared opaque TSLanguage) + modulemap. -------------
# Nested under a module-named subdir so the packaged headers copy to
# `$(BUILT_PRODUCTS_DIR)/include/TreeSitterGrammars/` instead of the shared
# `include/` root — otherwise this xcframework's `module.modulemap` collides with
# GhosttyKit's (both static xcframeworks flatten Headers into `include/`). clang
# still auto-discovers the module via the `<ModuleName>/module.modulemap` convention.
module_headers_dir="${headers_dir}/TreeSitterGrammars"
mkdir -p "${module_headers_dir}"
umbrella="${module_headers_dir}/TreeSitterGrammars.h"
{
  echo "#ifndef TREE_SITTER_GRAMMARS_H"
  echo "#define TREE_SITTER_GRAMMARS_H"
  echo ""
  echo "// Opaque forward declaration: pointers to an incomplete C struct import into"
  echo "// Swift as OpaquePointer, which SwiftTreeSitter.Language(_:) accepts directly."
  echo "typedef struct TSLanguage TSLanguage;"
  echo ""
  for ((i = 0; i < count; i++)); do
    echo "const TSLanguage *tree_sitter_${symbols[$i]}(void);"
  done
  echo ""
  echo "#endif"
} > "${umbrella}"

cat > "${module_headers_dir}/module.modulemap" <<'EOF'
module TreeSitterGrammars {
    header "TreeSitterGrammars.h"
    export *
}
EOF

# --- Assemble the xcframework. ---------------------------------------------------
xcodebuild -create-xcframework \
  -library "${fat_lib}" \
  -headers "${headers_dir}" \
  -output "${xcframework_path}"

printf '%s\n' "${fingerprint}" > "${fingerprint_path}"
compute_provenance > "${provenance_path}"
