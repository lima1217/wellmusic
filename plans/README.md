# Animation plans

Written by the improve-animations audit at commit bd23961. Each plan is
self-contained: hand it to any agent, which edits only the files it names.

| # | Plan | Severity | Status |
| --- | --- | --- | --- |
| 001 | [Move the notice line into the header so the page never jumps](001-notice-in-header.md) | MEDIUM | DONE |
| 002 | [Shape the pause/resume volume ramp with a raised-cosine curve](002-raised-cosine-fade.md) | LOW | DONE (listen-check pending) |

## Execution order

1. **001** first — it fixes something users can misclick on.
2. **002** — independent of 001 (different files and functions); run in either
   order or in parallel.

No dependencies between the plans.

## Audit summary

The interface was already restrained: no UI element animates on keyboard or
high-frequency actions, Reduce Motion is honored (since bd23961), and the
remaining motion is native scroll momentum and edge rubber-banding. Settled
decisions respected, not reported: no track-change enter motion (removed in
6be6efe for idle cost), instant album open/close and queue panel toggle
(frequent navigation).

Missed opportunity, since done outside the plans: the icon-only transport
controls (shuffle, repeat, mute, playlist) now carry anchored tooltips that
name their current state; the SDK's warm window shows a neighbour's tooltip
without a second delay.
