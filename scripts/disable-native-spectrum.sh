#!/usr/bin/env bash
# Disable Native SDK macOS audio spectrum analysis (FFT tap + 25 Hz timer).
# WellMusic does not draw an analyzer; the host still installs MTAudioProcessingTap
# and arms a 40 ms spectrum timer on every play, which costs a few % CPU.
#
# The SDK compiles appkit_host.m into this app on each `native` build, so patching
# the installed CLI source is enough. Re-run after upgrading `@native-sdk/cli`.
set -euo pipefail

resolve_sdk_root() {
  if [[ -n "${NATIVE_SDK_CLI:-}" && -f "${NATIVE_SDK_CLI}/src/platform/macos/appkit_host.m" ]]; then
    echo "$NATIVE_SDK_CLI"
    return
  fi
  local candidates=(
    "/opt/homebrew/lib/node_modules/@native-sdk/cli"
    "/usr/local/lib/node_modules/@native-sdk/cli"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c/src/platform/macos/appkit_host.m" ]]; then
      echo "$c"
      return
    fi
  done
  local native_bin
  native_bin="$(command -v native)" || return 1
  local dir
  dir="$(cd "$(dirname "$native_bin")" && pwd -P)"
  if [[ -f "$dir/../lib/node_modules/@native-sdk/cli/src/platform/macos/appkit_host.m" ]]; then
    echo "$(cd "$dir/../lib/node_modules/@native-sdk/cli" && pwd -P)"
    return
  fi
  return 1
}

SDK_ROOT="$(resolve_sdk_root)" || {
  echo "disable-native-spectrum: could not locate @native-sdk/cli" >&2
  exit 1
}
HOST="$SDK_ROOT/src/platform/macos/appkit_host.m"
MARK="WELLMUSIC_NO_SPECTRUM"
if grep -q "$MARK" "$HOST"; then
  echo "disable-native-spectrum: already applied → $HOST"
  exit 0
fi

python3 - "$HOST" "$MARK" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
mark = sys.argv[2]
text = path.read_text()

old_tap = """- (void)audioInstallSpectrumTapForItem:(AVPlayerItem *)item asset:(AVURLAsset *)asset {
    __weak NativeSdkAppKitHost *weakSelf = self;"""

new_tap = f"""- (void)audioInstallSpectrumTapForItem:(AVPlayerItem *)item asset:(AVURLAsset *)asset {{
    /* {mark}: WellMusic has no analyzer — skip MTAudioProcessingTap install. */
    (void)item;
    (void)asset;
    return;
    __weak NativeSdkAppKitHost *weakSelf = self;"""

old_timer = """    if (!self.audioSpectrumTimer) {
        /* The analysis cadence (~25 Hz). Armed with the transport like
         * the position tick; the fire handler additionally requires
         * fresh tap samples, so a stalled or tapless playback emits
         * nothing — never stale bars. */
        NSTimer *tick = [NSTimer timerWithTimeInterval:NATIVE_SDK_SPECTRUM_INTERVAL_SECONDS
                                                target:self
                                              selector:@selector(audioSpectrumTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:tick forMode:NSRunLoopCommonModes];
        self.audioSpectrumTimer = tick;
    }"""

new_timer = f"""    /* {mark}: WellMusic has no analyzer — do not arm the ~25 Hz spectrum timer. */
    if (NO && !self.audioSpectrumTimer) {{
        NSTimer *tick = [NSTimer timerWithTimeInterval:NATIVE_SDK_SPECTRUM_INTERVAL_SECONDS
                                                target:self
                                              selector:@selector(audioSpectrumTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:tick forMode:NSRunLoopCommonModes];
        self.audioSpectrumTimer = tick;
    }}"""

if old_tap not in text:
    sys.exit(f"disable-native-spectrum: tap install block not found in {path}")
if old_timer not in text:
    sys.exit(f"disable-native-spectrum: spectrum timer block not found in {path}")

text = text.replace(old_tap, new_tap, 1).replace(old_timer, new_timer, 1)
path.write_text(text)
print(f"disable-native-spectrum: patched → {path}")
PY
