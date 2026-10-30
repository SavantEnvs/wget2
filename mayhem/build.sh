#!/usr/bin/env bash
#
# mayhem/build.sh — build wget2's libFuzzer harnesses (sanitized, plus run-once -standalone reproducers)
# and, separately and with NORMAL flags, the project's own unit-tests/ and tests/ suites for mayhem/test.sh.
# Offline and re-runnable: everything comes from the in-image apt packages and the gnulib submodule checkout.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ_BUILD="$SRC/mayhem/build-fuzz"
TEST_BUILD="$SRC/mayhem/build-test"
CONFIGURE_COMMON=(--disable-doc --disable-manywarnings --disable-nls --disable-shared --enable-static
                  --without-gpgme --with-plugin-support=no)

# 0) autotools bootstrap from the gnulib submodule (the generated tree is gitignored, so it is redone
#    after a `git clean -ffdX`). --no-git/--gnulib-srcdir keep it offline.
if [ ! -f gnulib/gnulib-tool ]; then
  echo "gnulib submodule is not checked out (clone with --recurse-submodules)" >&2; exit 1
fi
if [ ! -f configure ] || [ ! -f lib/Makefile.in ]; then
  ./bootstrap --no-git --gnulib-srcdir=gnulib --skip-po
fi

# 1) The project itself, sanitized + SanCov-instrumented (fuzzer-no-link: the engine is linked per harness).
#    UBSan's `function` check is relaxed: libwget deliberately calls callbacks (hash/compare/free/db_load) through
#    generic void*-typed function pointers, which trips it on the very first input of 7 harnesses. ASan and every
#    other UBSan check stay on and halting.
mkdir -p "$FUZZ_BUILD"
cd "$FUZZ_BUILD"
if [ ! -f Makefile ]; then
  "$SRC/configure" "${CONFIGURE_COMMON[@]}" --enable-fuzzing \
    CC="$CC" CFLAGS="-O1 $SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION" \
    LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE"
fi
make -j"$MAYHEM_JOBS"

# 2) Harnesses: each links twice — standalone driver first, then the libFuzzer engine.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o lsan_off.o
FUZZERS=$(cd "$SRC/fuzz" && ls *_fuzzer.c | sed 's/\.c$//')

rm -f $(for f in $FUZZERS; do echo "fuzz/$f"; done)
make -j"$MAYHEM_JOBS" -C fuzz $FUZZERS LIB_FUZZING_ENGINE="$FUZZ_BUILD/standalone_main.o $FUZZ_BUILD/lsan_off.o -fsanitize=fuzzer-no-link"
for f in $FUZZERS; do cp "fuzz/$f" "$SRC/$f-standalone"; done

rm -f $(for f in $FUZZERS; do echo "fuzz/$f"; done)
make -j"$MAYHEM_JOBS" -C fuzz $FUZZERS LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE $FUZZ_BUILD/lsan_off.o"
for f in $FUZZERS; do cp "fuzz/$f" "$SRC/$f"; done

# 3) The project's own suites, built with NORMAL flags (test.sh only runs them).
mkdir -p "$TEST_BUILD"
cd "$TEST_BUILD"
if [ ! -f Makefile ]; then
  env -u CFLAGS -u LDFLAGS -u CPPFLAGS "$SRC/configure" "${CONFIGURE_COMMON[@]}" \
    CC="$CC" CFLAGS="-O1 -g $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
fi
make -j"$MAYHEM_JOBS"
make -j"$MAYHEM_JOBS" -C unit-tests check TESTS=
make -j"$MAYHEM_JOBS" -C tests check TESTS=
