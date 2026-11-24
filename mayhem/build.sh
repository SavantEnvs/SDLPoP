#!/usr/bin/env bash
#
# mayhem/build.sh — build SDLPoP (`prince`) twice:
#   mayhem/out/prince       ASan+UBSan (halting) + SanCov, DWARF 3 — the Mayhem file-input target
#                           (`prince validate <replay.p1r>`: headless replay of a .P1R file).
#   mayhem/out-test/prince  upstream's normal flags (-std=c99 -O2) — the functional oracle test.sh runs.
# Upstream's src/Makefile writes objects into src/ and the binary to ../prince, so both builds compile
# the same source list (the Makefile's OBJ) out of tree here instead; the two never share objects.
# `prince` chdirs to its own directory and loads data/ (and SDLPoP.ini, mods/) from there, so each
# output dir gets symlinks back to the tree's data/, SDLPoP.ini and mods/.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
cd "$SRC"

SOURCES="main data seg000 seg001 seg002 seg003 seg004 seg005 seg006 seg007 seg008 seg009 seqtbl replay options lighting screenshot menu midi opl3 stb_vorbis"
SDL_CFLAGS=$(pkg-config --cflags sdl2 SDL2_image)
SDL_LIBS=$(pkg-config --libs sdl2 SDL2_image)

# build_prince <outdir> <cflags...>  — compile every source into <outdir>/obj and link <outdir>/prince
build_prince() {
  local out="$1"; shift
  local cflags="$*"
  mkdir -p "$out/obj"
  printf '%s\n' $SOURCES | xargs -P "$MAYHEM_JOBS" -I{} \
    sh -c "$CC -Wall -D_GNU_SOURCE=1 -std=c99 $cflags $SDL_CFLAGS -c src/{}.c -o $out/obj/{}.o"
  local objs=""
  for s in $SOURCES; do objs="$objs $out/obj/$s.o"; done
  echo "$objs"
}

link_tree() {
  local out="$1"
  for f in data SDLPoP.ini mods; do ln -sfn "../../$f" "$out/$f"; done
}

# 1) Fuzz target: the whole game sanitized + SanCov-instrumented (fuzzer-no-link is unconditional so
#    the no-sanitizer build is still coverage-instrumented), LeakSanitizer off at build time.
#    UBSan `alignment` is relaxed (only that check): the game's option/level structs are
#    `#pragma pack(1)` (types.h) and are written through plain `word*`/`dword*` pointers
#    (e.g. options.c:146), which trips on the very first startup, before any input is read.
#    Unaligned access is harmless on x86-64; ASan and the rest of UBSan stay halting.
UBSAN_RELAX=""
case "$SANITIZER_FLAGS" in *undefined*) UBSAN_RELAX="-fno-sanitize=alignment" ;; esac
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
objs=$(build_prince mayhem/out $FUZZ_CFLAGS)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o mayhem/out/obj/lsan_off.o
# No link-time overrides of game code: a replay whose body fails to load drops `prince validate` into
# upstream's interactive game loop, which Mayhem bounds with the Mayhemfile timeout (a timeout, by design).
$CC $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -fsanitize=fuzzer-no-link $objs mayhem/out/obj/lsan_off.o \
  -o mayhem/out/prince $SDL_LIBS -lm
link_tree mayhem/out

# 2) Oracle build: upstream's own flags (src/Makefile: -std=c99 -O2), no sanitizers, no -gdwarf-3.
objs=$(build_prince mayhem/out-test -O2 $COVERAGE_FLAGS)
$CC $COVERAGE_FLAGS $objs -o mayhem/out-test/prince $SDL_LIBS -lm
link_tree mayhem/out-test

ls -l mayhem/out/prince mayhem/out-test/prince
