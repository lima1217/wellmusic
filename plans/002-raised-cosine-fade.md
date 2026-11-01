# 002 — Shape the pause/resume volume ramp with a raised-cosine curve

- **Status**: DONE (executed after bd23961; listening check still pending on a real device)
- **Commit**: bd23961
- **Severity**: LOW
- **Category**: Easing & duration (applied to the audio ramp — the one piece of
  "motion" in this app that runs on every pause and resume)
- **Estimated scope**: 1 file (`src/model.zig`), ~10 lines changed

## Problem

Pausing and resuming ramp the player volume over 6 steps × 25 ms (150 ms) so the
waveform is not cut mid-cycle. The ramp is LINEAR in amplitude:

```zig
// src/model.zig:2971 — current
fn fadeLevel(model: *const Model) f32 {
    const fraction = @as(f32, @floatFromInt(model.fade_step)) / @as(f32, @floatFromInt(fade_steps));
    return model.effectiveVolume() * switch (model.fade) {
        .none => 1,
        .out => 1 - fraction,
        .in => fraction,
    };
}
```

A linear ramp has a corner at both ends — full slope the instant it starts and
the instant it reaches silence. Those corners are exactly where an audible
"tick" comes from, which is the artefact the ramp exists to remove. It also
sounds abrupt at the tail: the last 25 ms step drops from 17% straight to 0.

Whether the platform player already smooths volume changes between our steps
cannot be judged from code — this plan includes a listening check.

## Target

A raised-cosine (Hann) curve: zero slope at both ends, same 6 steps, same
150 ms, same timer, same reversal behaviour.

```zig
// target
fn fadeLevel(model: *const Model) f32 {
    const fraction = @as(f32, @floatFromInt(model.fade_step)) / @as(f32, @floatFromInt(fade_steps));
    // Raised cosine: flat at both ends, so neither the start of the ramp
    // nor its arrival at silence leaves a corner in the waveform. The two
    // directions mirror each other exactly — out(k) == in(fade_steps - k) —
    // which keeps a mid-ramp reversal (startFade) continuous.
    const rising = 0.5 - 0.5 * @cos(std.math.pi * fraction);
    return model.effectiveVolume() * switch (model.fade) {
        .none => 1,
        .out => 1 - rising,
        .in => rising,
    };
}
```

Exact gain multipliers this produces for steps k = 0…6 (use them in the test):

| k | out | in |
| --- | --- | --- |
| 0 | 1.0000 | 0.0000 |
| 1 | 0.9330 | 0.0670 |
| 2 | 0.7500 | 0.2500 |
| 3 | 0.5000 | 0.5000 |
| 4 | 0.2500 | 0.7500 |
| 5 | 0.0670 | 0.9330 |
| 6 | 0.0000 | 1.0000 |

## Repo conventions to follow

- The ramp constants live beside `fadeLevel` in `src/model.zig`
  (`fade_step_ms = 25`, `fade_steps = 6`, `fade_timer_key = 46`); keep them.
- `std` is already imported at the top of `src/model.zig`; `@cos` and
  `std.math.pi` need no new import.
- Tests for the ramp live in `src/tests.zig` next to
  `test "pause ramps the volume down before the player stops"` — add the new
  test right after it, in the same style (`model_mod.Effects.init`, fake
  executor, `applyFx`).

## Steps

1. In `src/model.zig`, replace the body of `fadeLevel` with the Target body.
   Keep the function signature and its position.
2. Make `fadeLevel` reachable from tests: change `fn fadeLevel` to
   `pub fn fadeLevel`.
3. In `src/tests.zig`, after the "pause ramps the volume down…" test, add:

   ```zig
   test "the pause ramp is flat at both ends" {
       var model: Model = .{};
       model.volume = 1;
       model.fade = .out;
       const expected = [_]f32{ 1.0, 0.9330, 0.75, 0.5, 0.25, 0.0670, 0.0 };
       for (expected, 0..) |gain, k| {
           model.fade_step = @intCast(k);
           try testing.expectApproxEqAbs(gain, model_mod.fadeLevel(&model), 0.001);
       }
       // Reversal continuity: in(steps - k) == out(k).
       model.fade = .in;
       model.fade_step = model_mod.fade_steps - 2;
       try testing.expectApproxEqAbs(@as(f32, 0.75), model_mod.fadeLevel(&model), 0.001);
   }
   ```

4. Run the mechanical checks.

## Boundaries

- Do NOT change `fade_step_ms`, `fade_steps`, the timer, `startFade`,
  `fadeTick`, `stopFade`, or `setPlaying`.
- Do NOT add steps: every step is a timer Msg and a full UI rebuild.
- Do NOT touch any other file besides `src/model.zig` and `src/tests.zig`.
- If `fadeLevel` no longer matches the excerpt above (drift since commit
  bd23961), STOP and report instead of improvising.

## Verification

- **Mechanical** (from the repo root, with `$(npm prefix -g)/bin` on `PATH`):
  `native test --yes` → all tests pass, including the new one;
  `native check` → no warnings.
- **Feel check (listen)**: `native build --yes`, run `./zig-out/bin/wellmusic`,
  play a track with sustained tone (piano, strings — not a drum loop), then with
  headphones:
  - Press Space to pause and resume 10 times: no tick or click at the start or
    the end of either ramp.
  - Press Space twice quickly (within ~100 ms): the volume turns around smoothly
    with no jump.
  - Compare against the previous build if you can: the tail of the pause should
    sound like a soft close rather than a step to silence.
  - If you hear a faint "zipper" (stair-step) texture during the ramp, report it
    — it would mean the platform applies each step instantly, and the fix would
    be more steps, which this plan deliberately does not do.
- **Done when**: the new test passes and pausing/resuming on headphones has no
  audible tick.
