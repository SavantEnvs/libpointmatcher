#!/usr/bin/env bash
#
# mayhem/build.sh — build libpointmatcher's fuzz harness(es) + its test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The org base
# (ghcr.io/mayhemheroes/base) exports the build contract: CC, CXX, LIB_FUZZING_ENGINE,
# STANDALONE_FUZZ_MAIN, SANITIZER_FLAGS, SRC. apt deps (eigen3, boost, yaml-cpp) are installed
# by the Dockerfile as root. libnabo (libpointmatcher's kd-tree dep, third-party, not in this tree)
# is built once by the Dockerfile into /opt/toolchains/libnabo.
#
# Target `lib-fuzz` (binary /mayhem/fuzz_lib): fuzzes PointMatcher<float>::DataPoints::load() on a
# temp .csv/.vtk file → exercises libpointmatcher's CSV + VTK point-cloud parsers (pointmatcher/IO.cpp).
#
# ADDITIVE: upstream is built exactly as it documents (cmake), no upstream file is edited. The library
# code linked into the fuzz binaries is built WITH $SANITIZER_FLAGS so the fuzzed parser code is
# instrumented (not just the harness); the gtest `utest` suite is a SEPARATE clean build with normal
# flags so test.sh is an honest oracle.
#
# COVERAGE: the sanitized library is ALSO compiled with -fsanitize=fuzzer-no-link (SanitizerCoverage
# only: inline 8-bit counters, PC table, cmp tracing; no libFuzzer runtime, no main). $SANITIZER_FLAGS
# carries no coverage flags and $LIB_FUZZING_ENGINE only instruments the TU it is compiled into, so
# without it libFuzzer/Mayhem saw coverage edges from the harness file alone and none from
# libpointmatcher's parsers. It is added unconditionally, also when $SANITIZER_FLAGS is empty.
#
# BUILD COST (issue #1099, the graded rebuild must fit a 450 s window): the fuzz binaries only link
# the libpointmatcher.a members they reference. That is 9 of the 64 (IO, DataPoints, Inspector, …).
# None of the expensive Eigen solver/filter TUs (SurfaceNormal, PointToPlane, Gestalt, …) are in it.
# Building all 64 TUs a second time with ASan+UBSan+DWARF only to have the linker throw 55 of them
# away was most of the rebuild. Step 3 below compiles, with sanitizers, exactly the members the link
# pulls, and works that set out from the PATCHED tree on every run. Nothing is hardcoded and nothing
# is cached across runs.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF < 4 symbols independently of the sanitizer off-switch.
# clang-19's plain -g emits DWARF-5; -gdwarf-3 is explicit (Mayhem triage requires < 4).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# SanitizerCoverage for the fuzzed library code (see COVERAGE above). Not a sanitizer: it adds no
# checks, it only gives the fuzzer edge feedback from the library.
COV_FLAGS="-fsanitize=fuzzer-no-link"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# Idempotency + cold rebuild: remove every build dir, so a re-run on an already-built tree exits 0
# and recompiles the project's own sources from scratch.
rm -rf "$SRC/build-fuzz" "$SRC/build-tests" "$SRC/.deps"
# Build dirs MUST be gitignored (SPEC §6.2 item 16), so that the grader's `git clean -ffdX` removes
# them along with their CMakeCache.txt/build.ninja. Upstream's root .gitignore is an upstream file
# and does not cover build-fuzz/ or build-tests/, so each dir gets its own self-ignoring .gitignore
# (`*` also matches the .gitignore itself; the meson convention). The clean then removes the whole
# dir. The paths stay the same, so test.sh is unchanged.
for d in build-fuzz build-tests; do
  mkdir -p "$SRC/$d"
  printf '# created by mayhem/build.sh: ignore this whole build dir\n*\n' > "$SRC/$d/.gitignore"
done

NABO_PREFIX=/opt/toolchains/libnabo   # built by mayhem/Dockerfile (third-party, outside the tree)
[ -f "$NABO_PREFIX/lib/libnabo.a" ] || { echo "FATAL: $NABO_PREFIX/lib/libnabo.a missing — rebuild the image" >&2; exit 1; }
FDP_INC="$("$CC" -print-resource-dir)/include/fuzzer"   # base ships fuzzer/FuzzedDataProvider.h here

COMMON_CMAKE=(
  -G Ninja
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DCMAKE_PREFIX_PATH="$NABO_PREFIX"
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_EXAMPLES=OFF -DBUILD_EVALUATIONS=OFF -DBUILD_PYTHON_MODULE=OFF
  -DUSE_OPEN_MP=FALSE
)

# ----------------------------------------------------------------------------------------------
# 1) Configure both trees.
#    build-fuzz : INSTRUMENTED (the fuzzed code) — sanitizer + coverage + DWARF-3 flags on the
#                 library sources.
#    build-tests: the test suite — the gtest `utest` runner and a library built with the project's
#                 NORMAL Release flags (no sanitizers), so test.sh stays an honest functional oracle.
# ----------------------------------------------------------------------------------------------
cmake -S "$SRC" -B "$SRC/build-fuzz" "${COMMON_CMAKE[@]}" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS" \
  -DBUILD_TESTS=OFF
cmake -S "$SRC" -B "$SRC/build-tests" "${COMMON_CMAKE[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTS=ON

# ----------------------------------------------------------------------------------------------
# 2) TEST suite + its library, with normal flags. Its libpointmatcher.a is also the symbol index
#    that step 3 uses to work out which members the fuzz link pulls. Only its symbol table is read.
#    No object from this build is linked into a fuzz binary.
# ----------------------------------------------------------------------------------------------
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target utest
ORACLE_A="$SRC/build-tests/libpointmatcher.a"
[ -x "$SRC/build-tests/utest/utest" ] || { echo "FATAL: utest runner not produced" >&2; exit 1; }
[ -f "$ORACLE_A" ] || { echo "FATAL: $ORACLE_A not produced by the test build" >&2; exit 1; }

# ----------------------------------------------------------------------------------------------
# 3) Harness objects, then the sanitized library members the fuzz link needs.
#
#    Harness, built twice: (a) libFuzzer object, (b) object for the standalone run-once reproducer.
#    The standalone driver is C — compile it as a C object first so its LLVMFuzzerTestOneInput
#    reference keeps C linkage (clang++ would mangle it and miss the harness's extern "C" def).
#
#    lsan_off.c: the build-time __lsan_is_turned_off() hook (SPEC §6.2 item 15) disables LSan only.
#    LSan ptrace-attaches at exit which conflicts with Mayhem's ptrace-based coverage collection
#    → 0-edge "Run Failed". Linked into both binaries.
# ----------------------------------------------------------------------------------------------
HARNESS_DIR="$SRC/build-fuzz/harness"
mkdir -p "$HARNESS_DIR"
HARNESS_INCLUDES=( -I"$SRC" -I"$SRC/pointmatcher" -I"$FDP_INC" -I/usr/include/eigen3 -I"$NABO_PREFIX/include" )

"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o /tmp/lsan_off.o
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$HARNESS_DIR/standalone_main.o"
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${HARNESS_INCLUDES[@]}" $LIB_FUZZING_ENGINE \
  -c "$SRC/mayhem/fuzz_lib.cpp" -o "$HARNESS_DIR/fuzz_lib.o" &
fuzz_obj_pid=$!
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 "${HARNESS_INCLUDES[@]}" \
  -c "$SRC/mayhem/fuzz_lib.cpp" -o "$HARNESS_DIR/fuzz_lib-standalone.o"
wait "$fuzz_obj_pid"

# Link lines for the two binaries, minus the libpointmatcher archive (slotted in by link_fuzz).
# Libraries after the archive: libnabo, yaml-cpp, boost, pthread, as before.
TAIL_LIBS=( "$NABO_PREFIX/lib/libnabo.a" -lyaml-cpp
            -lboost_thread -lboost_system -lboost_program_options -lboost_date_time -lboost_chrono
            -lpthread )
link_fuzz() {      # link_fuzz <out> <archive>... [extra ld args]
  local out="$1"; shift
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 \
    "$HARNESS_DIR/fuzz_lib.o" /tmp/lsan_off.o "$@" "${TAIL_LIBS[@]}" $LIB_FUZZING_ENGINE -o "$out"
}
# The standalone reproducer links the same coverage-instrumented library objects, so its link also
# names $COV_FLAGS. With $SANITIZER_FLAGS set, that does not change the link at all (clang's driver
# emits the identical command: ASan's runtime already defines the weak __sanitizer_cov_* callbacks).
# With $SANITIZER_FLAGS empty, it pulls the sanitizer_common runtime that defines them, without which
# the instrumented objects would not link. Either way the reproducer runs no fuzzing loop.
link_standalone() {
  local out="$1"; shift
  "$CXX" $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS -std=c++17 \
    "$HARNESS_DIR/fuzz_lib-standalone.o" /tmp/lsan_off.o "$HARNESS_DIR/standalone_main.o" "$@" \
    "${TAIL_LIBS[@]}" -o "$out"
}

# Which members does the link pull? A static archive contributes a member only when the member
# defines a symbol the link still needs. So a sanitized archive holding just the needed members
# produces the same binary as the full sanitized libpointmatcher.a. Extra members never matter,
# they are not pulled. Missing ones are what we must rule out. We work the set out from the
# patched tree:
#
#   S = {} ; loop: build sanitized S into SUB_A, then link the harness against SUB_A followed by the
#   full normal-flags ORACLE_A (same sources, same external symbols; every TU is compiled in both
#   trees with identical -D defines, so the symbol index is the same).
#   If the link pulls anything from ORACLE_A, the sanitized S is missing a member that the real
#   archive would provide. That holds even when a later library (libnabo, libc, …) could also have
#   resolved the symbol, because ORACLE_A sits exactly where libpointmatcher.a sits. Add those
#   members and repeat. Stop when ORACLE_A contributes nothing: then SUB_A alone is equivalent to
#   the full archive. These probe links are thrown away. The shipped binaries link SUB_A only, so
#   every pulled member is the sanitized+DWARF-3 build of the patched source.
#
#   If the probe cannot settle (a link error, or it does not converge), fall back to building
#   the WHOLE sanitized library, which is what this script did before #1099. Correctness never
#   depends on the shortcut.
FUZZ_OBJDIR="CMakeFiles/pointmatcher.dir"
SUB_A="$SRC/build-fuzz/libpointmatcher-linked.a"
PROBE_DIR="$SRC/build-fuzz/probe"
mkdir -p "$PROBE_DIR"
declare -A WANT=()          # object path relative to the build dir, e.g. CMakeFiles/pointmatcher.dir/pointmatcher/IO.cpp.o
mapfile -t ORACLE_MEMBERS < <(ar t "$ORACLE_A")   # archive order, to keep SUB_A in the same order

pulled_from_oracle() {      # print oracle members a link map says were pulled
  grep -oE "build-tests/libpointmatcher\.a\([^)]+\)" "$1" | sed -E 's/.*\(([^)]+)\)$/\1/' | sort -u
}
add_member() {              # add every object in the fuzz tree whose archive member name is $1
  local m="$1" found=0 p
  while IFS= read -r p; do
    WANT["${p#"$SRC/build-tests/"}"]=1; found=1
  done < <(find "$SRC/build-tests/$FUZZ_OBJDIR" -type f -name "$m")
  [ "$found" = 1 ] || { echo "probe: oracle member $m has no object file" >&2; return 1; }
}
build_sub_archive() {
  local objs=() o m
  # ninja target names are the object paths relative to build-fuzz
  cmake --build "$SRC/build-fuzz" -j"$MAYHEM_JOBS" --target "${!WANT[@]}" || return 1
  rm -f "$SUB_A"
  for m in "${ORACLE_MEMBERS[@]}"; do
    for o in "${!WANT[@]}"; do
      [ "$(basename "$o")" = "$m" ] && objs+=( "$SRC/build-fuzz/$o" )
    done
  done
  # de-duplicate (a member name like Identity.cpp.o occurs twice and matched twice above)
  mapfile -t objs < <(printf '%s\n' "${objs[@]}" | awk '!seen[$0]++')
  ar qc "$SUB_A" "${objs[@]}" && ranlib "$SUB_A"
}

LPM_A=""
for iter in 1 2 3 4 5 6 7 8; do
  new=()
  if [ "${#WANT[@]}" -eq 0 ]; then archives=( "$ORACLE_A" ); else archives=( "$SUB_A" "$ORACLE_A" ); fi
  link_fuzz       "$PROBE_DIR/fuzz"       "${archives[@]}" -Wl,-Map="$PROBE_DIR/fuzz.map"       >/dev/null 2>&1 || break
  link_standalone "$PROBE_DIR/standalone" "${archives[@]}" -Wl,-Map="$PROBE_DIR/standalone.map" >/dev/null 2>&1 || break
  mapfile -t new < <(cat <(pulled_from_oracle "$PROBE_DIR/fuzz.map") <(pulled_from_oracle "$PROBE_DIR/standalone.map") | sort -u)
  if [ "${#new[@]}" -eq 0 ]; then
    [ "${#WANT[@]}" -gt 0 ] && LPM_A="$SUB_A"
    break
  fi
  echo "probe[$iter]: fuzz link needs ${#new[@]} more libpointmatcher member(s): ${new[*]}"
  before=${#WANT[@]}; ok=1
  for m in "${new[@]}"; do add_member "$m" || ok=0; done
  [ "$ok" = 1 ] || break
  [ "${#WANT[@]}" -gt "$before" ] || break      # no progress: the flavours disagree, fall back
  build_sub_archive || break
done
rm -rf "$PROBE_DIR"

# When two members both strongly define one symbol, the full archive resolves it from whichever
# comes first, and a subset might pick the other. (That is an ODR violation, but don't let it
# change which code is linked.) In that case use the full archive.
if [ -n "$LPM_A" ]; then
  dup_syms="$(nm -A -g --defined-only "$ORACLE_A" 2>/dev/null \
              | awk '$(NF-1) ~ /^[TDBRGS]$/ { split($1, a, ":"); print a[2], $NF }' | sort -u \
              | awk '{ n[$2]++ } END { for (s in n) if (n[s] > 1) print s }')"
  if [ -n "$dup_syms" ]; then
    echo "probe: symbols strongly defined by more than one libpointmatcher member:" >&2
    printf '    %s\n' $dup_syms >&2
    LPM_A=""
  fi
fi

if [ -n "$LPM_A" ]; then
  echo "=== fuzz link uses ${#WANT[@]} sanitized libpointmatcher objects (all members it pulls) ==="
  printf '    %s\n' "${!WANT[@]}" | sort
else
  echo "=== member probe did not settle — building the whole sanitized libpointmatcher ===" >&2
  cmake --build "$SRC/build-fuzz" -j"$MAYHEM_JOBS" --target pointmatcher
  LPM_A="$SRC/build-fuzz/libpointmatcher.a"
  [ -f "$LPM_A" ] || { echo "FATAL: $LPM_A not produced by the instrumented build" >&2; exit 1; }
fi

# ----------------------------------------------------------------------------------------------
# 4) The shipped binaries: (a) libFuzzer binary, (b) standalone run-once reproducer.
# ----------------------------------------------------------------------------------------------
link_fuzz       /mayhem/fuzz_lib            "$LPM_A"
link_standalone /mayhem/fuzz_lib-standalone "$LPM_A"

echo "=== build.sh done: /mayhem/fuzz_lib, /mayhem/fuzz_lib-standalone, build-tests/utest/utest ==="
ls -l /mayhem/fuzz_lib /mayhem/fuzz_lib-standalone "$SRC/build-tests/utest/utest"
