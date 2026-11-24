#!/usr/bin/env bash
#
# mayhem/build.sh — build RecoilEngine's fuzz harnesses and the upstream unit tests used as the
# functional oracle. Runs inside the commit image as `mayhem` in /mayhem.
#
# The engine's CMake configure needs SDL2/OpenGL/DevIL/OpenAL and every git submodule, so the
# harnesses compile only the engine sources each parser needs — the same per-target source lists
# upstream uses for its unit tests (test/CMakeLists.txt) — with the fuzz flags. Header-only
# submodules the sources include (tracy, with tracing disabled) come from the pinned copy the
# Dockerfile caches under /opt/toolchains/deps.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${TRACY_DIR:=/opt/toolchains/deps/tracy-5d542dc/src}"
: "${STREFLOP_DIR:=/opt/toolchains/deps/streflop-570f86f/src}"
: "${FMT_DIR:=/opt/toolchains/deps/fmt-407c905/src}"
: "${NOWIDE_DIR:=/opt/toolchains/deps/nowide-de3bb55/src}"
: "${SEVENZIP_DIR:=/opt/toolchains/deps/pr-downloader-185cfba/src/src/lib/7z}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
R="$SRC/rts"
B="$SRC/mayhem/build"           # gitignored by mayhem/.gitignore
mkdir -p "$B/fuzz" "$B/test"

# The version header CMake would generate (ConfigureVersion.cmake), with fixed values: the
# network protocol version comes from SPRING_VERSION_ENGINE_MAJOR.
mkdir -p "$B/gen/System"
sed -e 's/@SPRING_VERSION_ENGINE@/2025.0/' -e 's/@SPRING_VERSION_ENGINE_MAJOR@/2025/' \
    -e 's/@SPRING_VERSION_ENGINE_MINOR@/0/' -e 's/@SPRING_VERSION_ENGINE_PATCH_SET@/0/' \
    -e 's/@SPRING_VERSION_ENGINE_COMMITS@/0/' -e 's/@SPRING_VERSION_ENGINE_HASH@/0000000/' \
    -e 's/@SPRING_VERSION_ENGINE_BRANCH@/mayhem/' -e 's/@SPRING_VERSION_ENGINE_ADDITIONAL@//' \
    -e 's/@SPRING_VERSION_ENGINE_RELEASE@/true/' \
    "$R/System/VersionGenerated.h.template" > "$B/gen/System/VersionGenerated.h.tmp"
cmp -s "$B/gen/System/VersionGenerated.h.tmp" "$B/gen/System/VersionGenerated.h" 2>/dev/null \
    || mv "$B/gen/System/VersionGenerated.h.tmp" "$B/gen/System/VersionGenerated.h"
rm -f "$B/gen/System/VersionGenerated.h.tmp"

# streflop is included as "lib/streflop/..." (a submodule); point that at the pinned copy.
mkdir -p "$B/gen/lib"
ln -sfn "$STREFLOP_DIR" "$B/gen/lib/streflop"

COMMON_INC=(-I"$R" -I"$B/gen" -I"$TRACY_DIR/public" -I"$NOWIDE_DIR/include" -I"$FMT_DIR/include")
CXXSTD=(-std=c++20)

# Logging sources every engine TU links against (test_List_sources in test/CMakeLists.txt).
LOG_SRCS=(
	System/SafeCStrings.c
	System/Log/Backend.cpp
	System/Log/LogUtil.c
	System/Log/DefaultFilter.cpp
	System/Log/DefaultFormatter.cpp
	System/Log/FramePrefixer.cpp
	System/Log/ConsoleSink.cpp
	System/Log/StreamSink.cpp
)

# compile <outdir> <flags> <src relative to rts/ or absolute>... ; sets OBJS
compile() {
	local out="$1"; shift
	local flags="$1"; shift
	local s o
	OBJS=()
	for s in "$@"; do
		case "$s" in /*) ;; *) s="$R/$s" ;; esac
		o="$out/$(echo "${s#$SRC/}" | tr '/' '_').o"
		local f="$flags"
		case "$s" in
			# creg registers classes in static initializers, before any input is read:
			# CR_REG_METADATA's CR_MEMBER(m) expands to `creg::GetType(null->m)` and
			# offsetof_creg(), `&null->m - null` (rts/System/creg/creg.h:209,480), on a null
			# `Type* null`. UBSan's `null` and `object-size` checks both report that as
			# "member access within null pointer of type 'Type'", at PlayerStatistics.cpp:10,
			# TeamStatistics.cpp:9 and our fuzz_creg_load.cpp:19,45, on every run. `alignment` and
			# `vptr` do not fire there and stay on: only `null` and `object-size` are relaxed, in these TUs.
			*/Game/Players/PlayerStatistics.cpp|*/Sim/Misc/TeamStatistics.cpp) f="$f $CREG_REG_RELAX" ;;
			# GameData::Pack() (GameData.cpp:81) writes the 16-bit size right after the 1-byte
			# message id through RawPacket::operator<< (RawPacket.h:81), a reinterpret_cast store
			# to an odd address, so every packet that decodes (the startscript.bin seed included)
			# trips UBSan's `alignment` check in Pack. That one check is relaxed in this one TU
			# (benign on the x86/ARM targets the engine ships); RawPacket, PackPacket and
			# UnpackPacket keep the full halting set.
			*/Game/GameData.cpp) f="$f -fno-sanitize=alignment" ;;
			# CRC.cpp includes <7zCrc.h> from the pinned 7-Zip SDK
			*/System/CRC.cpp) f="$f -I$SEVENZIP_DIR" ;;
		esac
		case "$s" in
			*.c) $CC  $f "${COMMON_INC[@]}" -DSYNCCHECK -DUNIT_TEST -c "$s" -o "$o" ;;
			*)   $CXX $f "${CXXSTD[@]}" "${COMMON_INC[@]}" $EXTRA_DEFS -c "$s" -o "$o" ;;
		esac
		OBJS+=("$o")
	done
}

CREG_REG_RELAX="-fno-sanitize=null,object-size"
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link"
TEST_FLAGS="-O1 $COVERAGE_FLAGS"

# lsan_off: leaks are not the bug class fuzzed here (SPEC §6.2 item 15)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/fuzz/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/fuzz/standalone_main.o"

# The 7-Zip C SDK's CRC-32 (from the pinned pr-downloader, upstream's `7zip` library), which
# rts/System/CRC.cpp wraps. A dependency, not the fuzzed code: built uninstrumented, with debug info.
mkdir -p "$B/deps/7z"
SEVENZIP_OBJS=()
for s in 7zCrc.c 7zCrcOpt.c CpuArch.c; do
	$CC $DEBUG_FLAGS -O1 -c "$SEVENZIP_DIR/$s" -o "$B/deps/7z/${s%.c}.o"
	SEVENZIP_OBJS+=("$B/deps/7z/${s%.c}.o")
done

# link_fuzzer <name> <harness.cpp> <extra defs> <engine srcs...>
link_fuzzer() {
	local name="$1" harness="$2" defs="$3"; shift 3
	local objdir="$B/fuzz/$name"; mkdir -p "$objdir"
	EXTRA_DEFS="$defs"
	compile "$objdir" "$FUZZ_FLAGS" "${LOG_SRCS[@]}" "$@"
	local objs=("${OBJS[@]}")
	compile "$objdir" "$FUZZ_FLAGS ${HARNESS_FLAGS:-}" "$SRC/mayhem/harnesses/$harness"
	objs+=("${OBJS[@]}")
	objs+=(${EXTRA_OBJS:-})
	$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${objs[@]}" "$B/fuzz/lsan_off.o" -lz -lpthread -ldl -o "$SRC/$name"
	$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${objs[@]}" "$B/fuzz/standalone_main.o" "$B/fuzz/lsan_off.o" -lz -lpthread -ldl -o "$SRC/$name-standalone"
}

# UNIT_TEST would compile out the zlib helpers GameData uses (StringUtil.h), so these two
# are built like the engine itself. GameData.cpp's `alignment` relaxation: see compile().
link_fuzzer fuzz_gamedata fuzz_gamedata.cpp "-DSYNCCHECK" \
	Game/GameData.cpp Game/GameVersion.cpp System/Net/RawPacket.cpp System/Net/PackPacket.cpp System/Net/UnpackPacket.cpp System/StringUtil.cpp
link_fuzzer fuzz_uriparser fuzz_uriparser.cpp "-DSYNCCHECK" \
	System/UriParser.cpp System/StringUtil.cpp
link_fuzzer fuzz_quadfield fuzz_quadfield.cpp "-DSYNCCHECK -DUNIT_TEST -DNOT_USING_CREG -DBUILDING_AI" \
	Sim/Misc/QuadField.cpp
# The harness registers its own creg classes, so it gets the same relaxation (see compile()).
HARNESS_FLAGS="$CREG_REG_RELAX" \
link_fuzzer fuzz_creg_load fuzz_creg_load.cpp "-DSYNCCHECK -DUNIT_TEST" \
	System/creg/Serializer.cpp System/creg/VarTypes.cpp System/creg/creg.cpp
# Replay reader: the source list of upstream's demotool (tools/DemoTool/CMakeLists.txt, built
# with -DTOOLS), with fmt compiled from its pinned source and CRC.cpp linked against the pinned
# 7-Zip SDK objects above (the demotool's `7zip` library).
EXTRA_OBJS="${SEVENZIP_OBJS[*]}" \
link_fuzzer fuzz_demoreader fuzz_demoreader.cpp "-DTOOLS -DSYNCCHECK" \
	Game/GameVersion.cpp Game/Players/PlayerStatistics.cpp Sim/Misc/TeamStatistics.cpp \
	System/FileSystem/FileHandler.cpp System/FileSystem/FileSystem.cpp System/FileSystem/GZFileHandler.cpp \
	System/Platform/Misc.cpp System/Platform/Linux/Hardware.cpp System/Sync/SHA512.cpp System/StringUtil.cpp \
	System/Net/RawPacket.cpp System/LoadSave/DemoFileExtension.cpp System/LoadSave/DemoReader.cpp \
	System/LoadSave/Demo.cpp System/Log/LogSinkHandler.cpp \
	System/creg/Serializer.cpp System/creg/VarTypes.cpp System/creg/creg.cpp \
	System/CRC.cpp "$FMT_DIR/src/format.cc"

# ---- functional oracle: upstream's own Catch2 unit tests for the fuzzed code (LoadSave = creg
# serializer, QuadField = ray queries; source lists from test/CMakeLists.txt) plus our
# known-answer test for GameData/UriParser, built with normal flags (no sanitizers).
T="$SRC/test"
mkdir -p "$B/test/catch" "$SRC/mayhem/build/bin"
EXTRA_DEFS="-DCATCH_AMALGAMATED_CUSTOM_MAIN"
COMMON_INC+=(-I"$T/lib/catch2")
[ -f "$B/test/catch/done" ] || {
	compile "$B/test/catch" "$TEST_FLAGS" "$T/lib/catch2/catch_amalgamated.cpp" "$T/lib/catch2/catch_main.cpp"
	touch "$B/test/catch/done"
}
CATCH_OBJS=("$B/test/catch/test_lib_catch2_catch_amalgamated.cpp.o" "$B/test/catch/test_lib_catch2_catch_main.cpp.o")

# build_test <name> <defs> <srcs...>
build_test() {
	local name="$1" defs="$2"; shift 2
	mkdir -p "$B/test/$name"
	EXTRA_DEFS="-DCATCH_AMALGAMATED_CUSTOM_MAIN $defs"
	compile "$B/test/$name" "$TEST_FLAGS" "${LOG_SRCS[@]}" "$@"
	$CXX $TEST_FLAGS "${OBJS[@]}" "${CATCH_OBJS[@]}" -lz -lpthread -o "$SRC/mayhem/build/bin/test_$name"
}
build_test LoadSave "-DSYNCCHECK -DUNIT_TEST" \
	"$T/engine/System/LoadSave/testCregLoadSave.cpp" System/creg/Serializer.cpp System/creg/VarTypes.cpp System/creg/creg.cpp
build_test QuadField "-DSYNCCHECK -DUNIT_TEST -DNOT_USING_CREG -DBUILDING_AI" \
	"$T/engine/Sim/Misc/testQuadField.cpp" Sim/Misc/QuadField.cpp
build_test GameDataUri "-DSYNCCHECK" \
	"$SRC/mayhem/tests/testGameDataUri.cpp" Game/GameData.cpp Game/GameVersion.cpp System/Net/RawPacket.cpp \
	System/Net/PackPacket.cpp System/Net/UnpackPacket.cpp System/StringUtil.cpp System/UriParser.cpp

echo "build.sh: done"
