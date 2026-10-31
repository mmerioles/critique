#!/bin/bash
# Builds Critique's phone helper (a Quick Settings tile) into
# Resources/critique-helper.apk without Gradle: javac → d8 → aapt2 → apksigner.
# Needs Java 17+ and the Android SDK (build-tools + a platform).
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
PLATFORM="$SDK/platforms/$(ls "$SDK/platforms" | sort -V | tail -1)"
ANDROID_JAR="$PLATFORM/android.jar"
if [ -z "${JAVA_HOME:-}" ]; then
  for j in /opt/homebrew/opt/openjdk@17 /opt/homebrew/opt/openjdk "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
    [ -x "$j/bin/java" ] && export JAVA_HOME="$j" && break
  done
fi
export PATH="$JAVA_HOME/bin:$PATH"

OUT=build
rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/dex"

javac -source 8 -target 8 -Xlint:-options -bootclasspath "$ANDROID_JAR" -d "$OUT/classes" $(find src -name '*.java')
"$BT/d8" --min-api 24 --lib "$ANDROID_JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
"$BT/aapt2" compile --dir res -o "$OUT/res.zip"
"$BT/aapt2" link -I "$ANDROID_JAR" --manifest AndroidManifest.xml --min-sdk-version 24 --target-sdk-version 34 \
  -o "$OUT/unsigned.apk" "$OUT/res.zip"
(cd "$OUT/dex" && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# The standard Android debug key, so reinstalls update in place.
KEY="$HOME/.android/debug.keystore"
if [ ! -f "$KEY" ]; then
  mkdir -p "$HOME/.android"
  keytool -genkeypair -keystore "$KEY" -storepass android -keypass android -alias androiddebugkey \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
fi
"$BT/apksigner" sign --v4-signing-enabled false --ks "$KEY" --ks-pass pass:android --key-pass pass:android \
  --out ../Resources/critique-helper.apk "$OUT/aligned.apk"
rm -rf "$OUT"
echo "built Resources/critique-helper.apk"
