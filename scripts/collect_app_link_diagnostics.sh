#!/usr/bin/env bash
# Best-effort diagnostics for the full-app link (called from the EXIT trap of build_app_ipa.sh; never fails the build).
# Needs OUT, DIAG, APPNAME, ROOT in the environment; the arguments after "--" are the xcodebuild arguments of the build.
# Writes $DIAG/summary.json (concise, machine readable) plus the evidence it is derived from. Large files are gzipped.
set +e
shift # "--"
DD="$OUT/DerivedData"
mkdir -p "$DIAG/targets"

# Effective settings of the app target (with the same command-line overrides as the build).
xcodebuild "$@" -showBuildSettings > "$DIAG/build-settings.full.txt" 2>"$DIAG/build-settings.err"
awk -v t="$APPNAME" '/^Build settings for action/ {on = ($0 ~ "target " t "\$")} on' "$DIAG/build-settings.full.txt" \
  | grep -E '^ *(GCC_PREPROCESSOR_DEFINITIONS|OTHER_CFLAGS|HEADER_SEARCH_PATHS|DEAD_CODE_STRIPPING|LD_GENERATE_MAP_FILE|LD_MAP_FILE_PATH|STRIP_INSTALLED_PRODUCT|STRIP_STYLE|COPY_PHASE_STRIP|LLVM_LTO|GCC_OPTIMIZATION_LEVEL|ONLY_ACTIVE_ARCH|ARCHS|EXECUTABLE_PATH|TARGET_BUILD_DIR|TARGET_TEMP_DIR|OBJECT_FILE_DIR_normal|EXCLUDED_SOURCE_FILE_NAMES|INCLUDED_SOURCE_FILE_NAMES|SDKROOT|OTHER_LDFLAGS) =' | cut -c1-4000 > "$DIAG/build-settings.relevant.txt"

# Compile command(s) of the bridge and the link command, exactly as xcodebuild ran them.
grep -n 'kt_audiocpp_bridge\.c' "$DIAG/xcodebuild.log" | grep -E 'clang|CompileC' | cut -c1-6000 > "$DIAG/bridge-compile-commands.txt"
grep -nE '^ *(Ld|Link) ' "$DIAG/xcodebuild.log" | cut -c1-500 > "$DIAG/link-steps.txt"
grep -E '/(clang|clang\+\+) .* -o .*(/KittenTTS2App\.app/KittenTTS2App|Objects-normal/[^ ]*/KittenTTS2App) ' "$DIAG/xcodebuild.log" | cut -c1-20000 > "$DIAG/app-link-command.txt"

# Per-target response files / file lists / output maps (small), keyed by their path under DerivedData.
find "$DD" -type f \( -name '*.resp' -o -name '*.LinkFileList' -o -name '*-OutputFileMap.json' -o -name '*.hmap.json' \) -size -2000k 2>/dev/null | while read -r f; do
  rel="${f#$DD/}"; dest="$DIAG/targets/$(echo "$rel" | tr '/' '_')"
  cp "$f" "$dest"
done

# Every candidate product (so a wrong-product inspection is visible).
find "$DD" -type f -name "$APPNAME" 2>/dev/null > "$DIAG/app-executable-candidates.txt"
find "$DD" -type f -name 'kt_audiocpp_bridge.o' 2>/dev/null > "$DIAG/bridge-objects.txt"
find "$DD" -type f -name '*LinkMap*' 2>/dev/null > "$DIAG/linkmaps.txt"
APP_EXE="$DD/Build/Products/Release-iphoneos/$APPNAME.app/$APPNAME"

# Bridge objects: architectures, symbols, build variant marker.
while read -r o; do
  [ -n "$o" ] || continue
  n="$DIAG/$(echo "${o#$DD/}" | tr '/' '_')"
  { echo "## $o"; lipo -info "$o"; echo "## nm -m"; nm -m "$o"; echo "## variant strings"; strings -a "$o" | grep 'kt-bridge-variant'; } > "$n.nm.txt" 2>&1
done < "$DIAG/bridge-objects.txt"

# App executable: filtered symbols (full table gzipped), undefined ones, variant marker.
if [ -f "$APP_EXE" ]; then
  lipo -info "$APP_EXE" > "$DIAG/app-lipo.txt" 2>&1
  nm -a -m "$APP_EXE" 2>/dev/null | gzip -9 > "$DIAG/app-nm-a-m.txt.gz"
  nm "$APP_EXE" 2>/dev/null | grep -E '_kt_|_audiocpp_|make_kitten_tts2|kitten_tts2' | head -500 > "$DIAG/app-symbols-filtered.txt"
  nm -u "$APP_EXE" 2>/dev/null | grep -E '_kt_|_audiocpp_|kitten_tts2' | head -200 > "$DIAG/app-undefined-filtered.txt"
  strings -a "$APP_EXE" | grep 'kt-bridge-variant' > "$DIAG/app-variant-strings.txt"
fi

# Link map of the app target: is the bridge object linked, and was _kt_load dead-stripped?
MAP=$(grep -E "/$APPNAME(\\.build)?/.*LinkMap|$APPNAME-LinkMap" "$DIAG/linkmaps.txt" | head -1)
if [ -n "$MAP" ] && [ -f "$MAP" ]; then
  gzip -9 -c "$MAP" > "$DIAG/app-linkmap.txt.gz"
  grep -n 'kt_audiocpp_bridge' "$MAP" | head -50 > "$DIAG/linkmap-bridge-lines.txt"
  grep -n -E '_kt_(load|runtime_linked|synthesize|synthesize_clone)\b' "$MAP" | head -50 > "$DIAG/linkmap-kt-symbols.txt"
  grep -n '^# Dead Stripped Symbols' "$MAP" > "$DIAG/linkmap-deadstrip-header.txt"
fi

python3 - <<'PY' > "$DIAG/summary.json" 2>"$DIAG/summary.err"
import json, os, re
d = os.environ["DIAG"]
def read(n):
    try:
        return open(os.path.join(d, n), errors="replace").read()
    except OSError:
        return ""
def lines(n):
    return [l for l in read(n).splitlines() if l.strip()]
settings = {}
for l in lines("build-settings.relevant.txt"):
    k, _, v = l.strip().partition(" = ")
    settings[k] = v[:500]
bridge_objs = []
for o in lines("bridge-objects.txt"):
    txt = read(os.path.join("", re.sub("/", "_", o.split("DerivedData/", 1)[-1])) + ".nm.txt")
    bridge_objs.append({
        "path": o,
        "defined_kt_symbols": sorted(set(re.findall(r"\(__TEXT,__text\) external (_kt_\w+)", txt))),
        "undefined_audiocpp_refs": sorted(set(re.findall(r"undefined \(.*?\) external (_audiocpp_\w+)", txt)))[:20],
        "variant": re.findall(r"kt-bridge-variant:[\w-]+", txt),
    })
exe_syms = read("app-symbols-filtered.txt")
def exe_has(sym):
    return [l for l in exe_syms.splitlines() if re.search(r" \w " + sym + r"$", l)]
log = read("xcodebuild.log")
map_lines = read("linkmap-kt-symbols.txt")
dead_hdr = read("linkmap-deadstrip-header.txt").strip()
summary = {
    "xcodebuild_build_succeeded": "** BUILD SUCCEEDED **" in log,
    "app_executable_candidates": lines("app-executable-candidates.txt"),
    "effective_settings": settings,
    "bridge_compile_command_count": len(lines("bridge-compile-commands.txt")),
    "bridge_compile_has_KT_NATIVE_LINKED": ["KT_NATIVE_LINKED=1" in l for l in lines("bridge-compile-commands.txt")],
    "bridge_objects": bridge_objs,
    "app_variant_strings": lines("app-variant-strings.txt"),
    "app_lipo": read("app-lipo.txt").strip(),
    "app_defined_symbols": {s: exe_has(s) for s in ["_kt_runtime_linked", "_kt_load", "_kt_synthesize", "_kt_synthesize_clone", "_kt_bridge_build_variant", "_audiocpp_model_load", "_audiocpp_session_run"]},
    "app_has_kitten_tts2_loader": "make_kitten_tts2_loader" in exe_syms,
    "linkmap_found": os.path.exists(os.path.join(d, "app-linkmap.txt.gz")),
    "linkmap_mentions_bridge_object": bool(lines("linkmap-bridge-lines.txt")),
    "linkmap_has_dead_stripped_section": bool(dead_hdr),
    "linkmap_kt_symbol_lines": map_lines.splitlines()[:20],
    "files": sorted(os.listdir(d)),
}
print(json.dumps(summary, indent=2))
PY
cat "$DIAG/summary.json" 2>/dev/null
exit 0
