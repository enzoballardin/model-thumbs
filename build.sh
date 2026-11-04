#!/bin/bash
# ModelThumbs — builds and installs the Quick Look thumbnail extension.
#
#   ./build.sh            build + install (asks before installing OpenCASCADE for STEP)
#   ./build.sh --yes      don't ask, install OpenCASCADE with Homebrew if missing
#   ./build.sh --no-cad   skip STEP / IGES support
#   ./build.sh --no-install   only build into ./build
#
# Needs only Apple's Command Line Tools (xcode-select --install), not full Xcode.
# Optional STEP/IGES support needs Homebrew + OpenCASCADE (brew install opencascade).

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

APP_NAME="ModelThumbs"
APP_ID="com.modelthumbs.app"
EXT_NAME="ModelThumbsThumbnailer"
EXT_ID="$APP_ID.thumbnailer"
VERSION="1.0"

WANT_CAD=1; ASSUME_YES=0; INSTALL=1
for a in "$@"; do
  case "$a" in
    --no-cad) WANT_CAD=0 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --no-install) INSTALL=0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
step() { printf "\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$*"; }
warn() { printf "\033[33mwarning:\033[0m %s\n" "$*"; }
die()  { printf "\033[31merror:\033[0m %s\n" "$*"; exit 1; }

# ---------------------------------------------------------------- toolchain
step "Checking tools"
if ! SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || [ -z "$SDK" ]; then
  echo "Apple's Command Line Tools are missing. A dialog will open to install them;"
  echo "run ./build.sh again when it finishes."
  xcode-select --install || true
  exit 1
fi
command -v swiftc >/dev/null || die "swiftc not found (reinstall Command Line Tools: xcode-select --install)"
ARCH="$(uname -m)"
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
MIN_OS="13.0"
echo "SDK:   $SDK"
echo "Swift: $(swiftc --version 2>&1 | head -1)"
echo "Arch:  $ARCH, macOS $(sw_vers -productVersion)"

# ---------------------------------------------------------------- OpenCASCADE
OCCT=""
if [ "$WANT_CAD" = 1 ]; then
  step "STEP / IGES support (OpenCASCADE)"
  BREW="$(command -v brew || true)"
  [ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
  [ -z "$BREW" ] && [ -x /usr/local/bin/brew ] && BREW=/usr/local/bin/brew
  if [ -n "$BREW" ]; then
    P="$("$BREW" --prefix opencascade 2>/dev/null || true)"
    if [ -n "$P" ] && [ -d "$P/include/opencascade" ]; then
      OCCT="$P"
    else
      ANSWER="n"
      if [ "$ASSUME_YES" = 1 ]; then ANSWER="y"
      elif [ -t 0 ]; then
        read -r -p "OpenCASCADE isn't installed. Install it with Homebrew now for STEP/IGES thumbnails? [Y/n] " ANSWER || true
        ANSWER="${ANSWER:-y}"
      fi
      if [[ "$ANSWER" =~ ^[Yy] ]]; then
        "$BREW" install opencascade
        P="$("$BREW" --prefix opencascade)"
        [ -d "$P/include/opencascade" ] && OCCT="$P"
      fi
    fi
  else
    warn "Homebrew not found — building without STEP/IGES. Install Homebrew (https://brew.sh) and rerun to add it."
  fi
  if [ -n "$OCCT" ]; then
    echo "Using OpenCASCADE at $OCCT"
    MIN_OS="$OS_MAJOR.0"   # Homebrew libraries target the running macOS
  else
    echo "Continuing without STEP/IGES support."
  fi
fi
TARGET="$ARCH-apple-macos$MIN_OS"

# ---------------------------------------------------------------- file types
# id | description | extensions | needs CAD
TYPES=(
  "com.modelthumbs.3mf|3MF 3D Manufacturing File|3mf|0"
  "com.modelthumbs.amf|AMF Additive Manufacturing File|amf|0"
  "com.modelthumbs.off|OFF Mesh|off|0"
  "com.modelthumbs.glb|glTF Binary Model|glb|0"
  "com.modelthumbs.gltf|glTF Model|gltf|0"
  "com.modelthumbs.xyz|XYZ Point Cloud|xyz|0"
  "com.modelthumbs.pts|PTS Point Cloud|pts|0"
  "com.modelthumbs.gcode|G-code|gcode gco|0"
  "com.modelthumbs.bgcode|Binary G-code|bgcode|0"
  "com.modelthumbs.f3d|Fusion Design|f3d|0"
  "com.modelthumbs.f3z|Fusion Archive|f3z|0"
  "com.modelthumbs.ufp|Ultimaker Format Package|ufp|0"
  "com.modelthumbs.fcstd|FreeCAD Document|fcstd FCStd|0"
  "com.modelthumbs.sl1|Prusa SL1 Print|sl1 sl1s|0"
  "com.modelthumbs.lightburn|LightBurn Project|lbrn lbrn2|0"
  "com.modelthumbs.chitubox|Chitubox Resin Print|ctb cbddlp photon phz|0"
  "com.modelthumbs.goo|Elegoo / Phrozen Resin Print|goo prz|0"
  "com.modelthumbs.anycubic|Anycubic Resin Print|pws pw0 pwx dlp dl2p pwmx pmx2 pwmb px6s pwmo pm3n pm4n pwms pwma pmsq pm3 pm3m pm3r pm5 pm5s m5sp pwc|0"
  "com.modelthumbs.rhino|Rhino 3D Model|3dm|0"
  "com.modelthumbs.blend|Blender File|blend blend1|0"
  "com.modelthumbs.skp|SketchUp Model|skp|0"
  "com.modelthumbs.solidworks|SolidWorks Document|sldprt sldasm slddrw SLDPRT SLDASM SLDDRW|0"
  "com.modelthumbs.inventor|Inventor Document|ipt iam ipn idw|0"
  "com.modelthumbs.e57|E57 Point Cloud|e57|0"
  "com.modelthumbs.pcd|PCD Point Cloud|pcd|0"
  "com.modelthumbs.las|LAS Point Cloud|las|0"
  "com.modelthumbs.dae|Collada Model|dae|0"
  "com.modelthumbs.vrml|VRML Model|wrl vrml|0"
  "com.modelthumbs.x3d|X3D Model|x3d|0"
  "com.modelthumbs.3ds|3D Studio Model|3ds|0"
  "com.modelthumbs.step|STEP CAD Model|step stp p21|1"
  "com.modelthumbs.iges|IGES CAD Model|iges igs|1"
  "com.modelthumbs.brep|BREP CAD Model|brep brp|1"
)
# Types macOS already defines (OBJ, PLY)
SYSTEM_TYPES=("public.geometry-definition-format" "public.polygon-file-format")

BUILD="$ROOT/build"
rm -rf "$BUILD"; mkdir -p "$BUILD/obj"

step "Looking up file type identifiers already registered on this Mac"
swiftc -O -target "$ARCH-apple-macos13.0" -sdk "$SDK" Tools/uticheck.swift -o "$BUILD/uticheck"
EXTS="3mf amf off glb gltf xyz pts gcode gco bgcode f3d f3z obj ply 3dm 3ds blend blend1 cbddlp ctb dae dl2p dlp e57 fcstd goo iam idw ipn ipt las lbrn lbrn2 m5sp pcd photon phz pm3 pm3m pm3n pm3r pm4n pm5 pm5s pmsq pmx2 prz pw0 pwc pwma pwmb pwmo pwms pwmx pws pwx px6s skp sl1 sl1s sldasm slddrw sldprt ufp vrml wrl x3d"
[ -n "$OCCT" ] && EXTS="$EXTS step stp p21 iges igs brep brp"
# shellcheck disable=SC2086
EXTRA_TYPES="$("$BUILD/uticheck" $EXTS | tee /dev/stderr | cut -f2 | sort -u || true)"

SUPPORTED=()
IMPORTED=""
for t in "${TYPES[@]}"; do
  IFS='|' read -r id desc exts cad <<<"$t"
  [ "$cad" = 1 ] && [ -z "$OCCT" ] && continue
  SUPPORTED+=("$id")
  extxml=""
  for e in $exts; do extxml="$extxml<string>$e</string>"; done
  IMPORTED="$IMPORTED
    <dict>
      <key>UTTypeIdentifier</key><string>$id</string>
      <key>UTTypeDescription</key><string>$desc</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array>$extxml</array></dict>
    </dict>"
done
SUPPORTED+=("${SYSTEM_TYPES[@]}")
for x in $EXTRA_TYPES; do SUPPORTED+=("$x"); done
SUPPORTED_XML=""
for s in $(printf "%s\n" "${SUPPORTED[@]}" | sort -u); do SUPPORTED_XML="$SUPPORTED_XML<string>$s</string>"; done

# ---------------------------------------------------------------- compile
SWIFT_COMMON=(-O -wmo -swift-version 5 -target "$TARGET" -sdk "$SDK")
CAD_SWIFT=(); CAD_LINK=()
if [ -n "$OCCT" ]; then
  step "Compiling OpenCASCADE bridge"
  clang++ -std=c++17 -O2 -target "$TARGET" -isysroot "$SDK" \
    -I"$OCCT/include/opencascade" -c Sources/CAD/mt_cad.cpp -o "$BUILD/obj/mt_cad.o" -w
  LIBS=""
  for l in TKernel TKMath TKG2d TKG3d TKGeomBase TKBRep TKGeomAlgo TKTopAlgo TKMesh TKShHealing TKXSBase \
           TKDE TKDESTEP TKDEIGES TKSTEP TKSTEPBase TKSTEP209 TKSTEPAttr TKIGES; do
    if ls "$OCCT/lib/lib$l".*dylib >/dev/null 2>&1 || [ -e "$OCCT/lib/lib$l.dylib" ]; then LIBS="$LIBS -l$l"; fi
  done
  echo "Linking:$LIBS"
  CAD_SWIFT=(-D MT_HAS_OCCT -import-objc-header Sources/CAD/mt_cad.h Sources/CAD/CADLoader.swift "$BUILD/obj/mt_cad.o")
  # shellcheck disable=SC2206
  CAD_LINK=(-L"$OCCT/lib" $LIBS -lc++)
fi

step "Compiling Quick Look extension"
swiftc "${SWIFT_COMMON[@]}" -module-name "$EXT_NAME" -parse-as-library -application-extension \
  Sources/Core/*.swift Sources/Extension/*.swift ${CAD_SWIFT[@]+"${CAD_SWIFT[@]}"} ${CAD_LINK[@]+"${CAD_LINK[@]}"} \
  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -headerpad_max_install_names \
  -o "$BUILD/obj/$EXT_NAME"

step "Compiling host app and command-line renderer"
swiftc "${SWIFT_COMMON[@]}" -module-name "$APP_NAME" Sources/App/main.swift -o "$BUILD/obj/$APP_NAME"
swiftc "${SWIFT_COMMON[@]}" -module-name modelthumbs_render \
  Sources/Core/*.swift Sources/CLI/main.swift ${CAD_SWIFT[@]+"${CAD_SWIFT[@]}"} ${CAD_LINK[@]+"${CAD_LINK[@]}"} \
  -Xlinker -headerpad_max_install_names -o "$BUILD/obj/modelthumbs-render"

# ---------------------------------------------------------------- bundle
step "Assembling $APP_NAME.app"
APP="$BUILD/$APP_NAME.app"
EXT="$APP/Contents/PlugIns/$EXT_NAME.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
cp "$BUILD/obj/$APP_NAME" "$APP/Contents/MacOS/"
cp "$BUILD/obj/modelthumbs-render" "$APP/Contents/MacOS/"
cp "$BUILD/obj/$EXT_NAME" "$EXT/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$APP_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTImportedTypeDeclarations</key>
  <array>$IMPORTED
  </array>
</dict>
</plist>
EOF

cat > "$EXT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$EXT_NAME</string>
  <key>CFBundleIdentifier</key><string>$EXT_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$EXT_NAME</string>
  <key>CFBundleDisplayName</key><string>ModelThumbs</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.quicklook.thumbnail</string>
    <key>NSExtensionPrincipalClass</key><string>ThumbnailProvider</string>
    <key>NSExtensionAttributes</key>
    <dict>
      <key>QLSupportedContentTypes</key>
      <array>$SUPPORTED_XML</array>
      <key>QLThumbnailMinimumDimension</key><integer>0</integer>
    </dict>
  </dict>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist" >/dev/null

if [ -n "$OCCT" ]; then
  step "Bundling OpenCASCADE libraries"
  python3 Tools/bundle_dylibs.py "$EXT/Contents/MacOS/$EXT_NAME" "$EXT/Contents/Frameworks" \
    "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/modelthumbs-render=@executable_path/../PlugIns/$EXT_NAME.appex/Contents/Frameworks"
fi

# ---------------------------------------------------------------- sign
step "Signing"
SIGN="-"
ID_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Apple Development|Developer ID Application)' | head -1 || true)"
if [ -n "$ID_LINE" ]; then
  SIGN="$(echo "$ID_LINE" | awk '{print $2}')"
  echo "Using certificate: $(echo "$ID_LINE" | sed -E 's/.*"(.*)"/\1/')"
else
  echo "Using local (ad-hoc) signature"
fi
sign() { codesign --force --sign "$SIGN" --timestamp=none "$@"; }
if [ -d "$EXT/Contents/Frameworks" ]; then
  for lib in "$EXT/Contents/Frameworks"/*.dylib; do sign "$lib" 2>/dev/null; done
fi
sign --entitlements Resources/Extension.entitlements "$EXT"
sign "$APP/Contents/MacOS/modelthumbs-render"
sign "$APP"
codesign --verify --strict "$EXT" && codesign --verify --strict "$APP"
echo "Extension entitlements:"; codesign -d --entitlements - "$EXT" 2>/dev/null | grep -E "sandbox|read-only" | sed 's/^/  /' || true

if [ "$INSTALL" = 0 ]; then bold "Built $APP"; exit 0; fi

# ---------------------------------------------------------------- install
step "Installing"
if [ -w /Applications ]; then DEST_DIR="/Applications"; else DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; fi
DEST="$DEST_DIR/$APP_NAME.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
if [ -d "$DEST" ]; then
  pluginkit -r "$DEST/Contents/PlugIns/$EXT_NAME.appex" 2>/dev/null || true
  "$LSREG" -u "$DEST" 2>/dev/null || true
  rm -rf "$DEST"
fi
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
"$LSREG" -f -R -trusted "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/$EXT_NAME.appex"
pluginkit -e use -i "$EXT_ID" || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "Installed to $DEST"

step "Checking registration"
sleep 2
REG="$(pluginkit -m -v -i "$EXT_ID" 2>/dev/null || true)"
if [ -n "$REG" ]; then echo "$REG"; else warn "pluginkit doesn't list the extension yet (see Troubleshooting in README.md)"; fi

step "Test thumbnails"
# 1) The renderer itself, with the installed (bundled) libraries: fast and reliable.
TMP="$(mktemp -d)"
RENDER="$DEST/Contents/MacOS/modelthumbs-render"
OK=0; TOTAL=0
for f in Samples/*; do
  ext="${f##*.}"
  if [[ "$ext" =~ ^(step|igs)$ ]] && [ -z "$OCCT" ]; then continue; fi
  TOTAL=$((TOTAL + 1))
  if "$RENDER" "$f" "$TMP/$(basename "$f").png" 256 >/dev/null 2>"$TMP/err.txt" && [ -s "$TMP/$(basename "$f").png" ]; then
    OK=$((OK + 1)); echo "  ok    $(basename "$f")"
  else
    echo "  FAIL  $(basename "$f"): $(head -c 200 "$TMP/err.txt")"
  fi
done
echo "$OK of $TOTAL samples rendered (images in $TMP)"

# 2) One end-to-end check through Quick Look. qlmanage can hang on some macOS
#    versions, so it gets a time limit and never blocks the install.
QL_FILE="Samples/sample.obj"
QL_DIR="$TMP/quicklook"; mkdir -p "$QL_DIR"
qlmanage -t -s 256 -o "$QL_DIR" "$QL_FILE" >/dev/null 2>&1 &
QL_PID=$!
for _ in $(seq 1 30); do
  [ -s "$QL_DIR/$(basename "$QL_FILE").png" ] && break
  kill -0 "$QL_PID" 2>/dev/null || break
  sleep 0.5
done
kill "$QL_PID" 2>/dev/null || true
wait "$QL_PID" 2>/dev/null || true
if [ -s "$QL_DIR/$(basename "$QL_FILE").png" ]; then
  echo "  ok    Quick Look produced a thumbnail through the extension"
else
  echo "  note  Quick Look's test tool didn't return a thumbnail within 15 s. This tool is"
  echo "        unreliable on recent macOS; check the icons in Finder instead."
fi

open "$DEST"
bold ""
bold "Done. Finder may take a moment to refresh icons; if not, use \"Refresh thumbnails\" in the app."
