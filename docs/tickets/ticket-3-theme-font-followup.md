# Ticket 3：theme 去重 + 字体内存减半 + 字体回退测试

优先级：低（纯重构 + 优化，无行为缺陷）
预估：2–3 小时
背景文档：`docs/code-review-spec.md` 第 O1、O2、O3、O4、O5.3、O6、O7 节（本票自包含）
依赖：无硬依赖；如 Ticket 1/2 同时进行，注意 `src/main.zig` 可能有合并冲突，建议排在其后。

## 背景

最近的改动给应用注册了系统 CJK 字体（`src/ui_font.zig`，启动时从 `/System/Library/Fonts/Supplemental/Arial Unicode.ttf` 读 ~23MB，经 `Options.fonts` 注册进 canvas），并让 `src/theme.zig` 的 `tokens()` 在运行时把该字体盖进 typography。这带来两处技术债。

## 任务一（O1）：消除 theme.zig 三份重复的 ThemeOptions

现状（`src/theme.zig` 约 223–252 行）：`tokens()` 内联构造 `ThemeOptions{ .pack = .geist, ... }` 并套 `accentOverridesFor`；文件底部导出的 `light_colors` / `dark_colors`（供 `tests.zig` 断言）因为不能碰运行时字体状态，各自又复制了一遍 `.pack = .geist` + `accentOverridesFor(...)`。三份的等价性当前只靠 `ThemeOptions` 的默认值（`contrast = .standard`、`reduce_motion = false`）恰好等于 `tokens()` 显式传的值——将来任何一处改 pack 或 contrast 会静默 drift，而现有测试只比对 colors，typography/motion 的 drift 抓不到。

**要求**：抽一个**纯函数**（comptime 可求值，不读任何运行时状态）：

```zig
fn standardTokens(scheme: canvas.ColorScheme) canvas.DesignTokens
```

包含 geist pack + `accentOverridesFor(scheme)`，标准对比度、不动 motion。然后：

- `tokens()` 在标准对比度路径调用它，再叠 reduce_motion 处理和 `withUiFont`（注意现状 `tokens()` 通过 `ThemeOptions.reduce_motion` 让 pack 自己归零 motion——保持该行为，实现方式可自选，但 reduce_motion 的效果必须不变；high-contrast 路径保持"跳过 accent override、仍套 withUiFont"的现有语义）。
- `light_colors = standardTokens(.light).colors`、`dark_colors = standardTokens(.dark).colors`。
- 完成后 `.pack = .geist` 与 `accentOverridesFor` 的调用点全文件各只剩一处。

## 任务二（O2）：释放字体原始字节（RSS 减半，~23MB）

事实（SDK：`/opt/homebrew/lib/node_modules/@native-sdk/cli/src/runtime/ui_app.zig`，`FontRegistration.ttf` 的文档）：SDK 在 installing frame 注册字体时**复制**字节（"Copied at registration, so transient buffers are fine"）。而 `ui_font.loaded_bytes` 永久持有原始 ~23MB —— 注册完成后这份就没用了：`theme.withUiFont` 只读 `ui_font.ready()` 和 `font_id`。

**要求**：

1. `ui_font.zig` 增加 `pub fn releaseBytes(allocator)`（或等价接口）：释放 `loaded_bytes`，但保留一个 `registered/loaded` 布尔，`ready()` 改读该布尔而非 `loaded_bytes.len`（theme 的字体判断在释放后必须仍然为 true）。
2. 释放时机必须在 installing frame **之后**（注册发生在首帧）。现成锚点：`src/main.zig` 的 `onFrame` 首次回调。实现建议：`main.zig` 加一个一次性标志，`onFrame` 第一次进来时调 `ui_font.releaseBytes(std.heap.page_allocator)`。注意 `onFrame` 签名是 `fn(*const Model, GpuFrame) ?Msg`，不能改 Model——一次性标志放 main.zig 文件级即可（这是平台生命周期钩子的状态，不是 Model 状态，加注释说明）。
3. 分配器身份：`load` 用的是 `std.heap.page_allocator`（`prepareUiFonts` 传入），释放必须用同一个。

**警惕**：确认 `Options.fonts` 切片（`main.zig` 的 `ui_font_regs`）在释放后不会再被 SDK 读——`ui_app.zig` 的 `fonts_registered` 标志保证注册 exactly-once，且发生在任何 `on_frame` 回调之前（installing frame 的 rebuild 先于 present）。在代码注释里写清这个时序依赖。

## 任务三（O5.3）：字体与 theme 的回退测试

`src/tests.zig` 补两条：

1. `ui_font.ready() == false` 时（测试环境默认如此——测试从不调 `prepareUiFonts`），`theme.tokens(.light, false, false).typography.font_id` 等于 pack 默认（即不等于 `ui_font.font_id`）。
2. high-contrast 路径的语义钉住：`theme.tokens(.light, true, false)` 的 colors 等于 pack 高对比 register（不带粉色 accent override）——这是现状注释声称但无测试保护的行为。

（真实加载字体后的 typography 断言不好做——测试机字体环境不可控，跳过；上面两条已足够钉住分支结构。）

## 任务四（顺手项，时间富余再做，不强求）

- **O3**：`ui_font.readAbsolute` 用 `allocRemaining` 增长式读取 23MB 文件，反复 realloc；改为先 stat 文件大小、精确分配、读满。保留 `.limited(max_font_bytes)` 等价的超限保护（超过 24MiB 必须失败跳过，不能截断）。
- **O4**：`ui_font.max_font_bytes` 硬编码 `24 * 1024 * 1024`；查 `native_sdk` 根是否导出 `canvas_limits.max_registered_canvas_font_bytes`，导出了就引用，没导出保持现状。
- **O6**：`ui_font.zig` 模块注释补一句：候选路径 macOS-only，iOS/Android 目标需另配路径或打包字体（`initModel` 的 mobile 路径当前会静默失败回到 tofu）。
- **O7**：`theme.withUiFont` 注释补一句：有意不覆盖 `mono_font_id`（当前无 CJK 文本走 mono 槽）。

## 验收

- `native test` 全绿（基线 33/33 + 任务三的两条新测试；现有 theme 测试比对 `light_colors`/`dark_colors` 必须原样通过——任务一如果引起这些测试变化，说明重构改变了 token 值，是错的）。
- `native check` 通过。
- 真跑一次 app（`native dev` 或 `native run`）：CJK 曲名正常渲染（回归任务二——如果释放时机错了，首帧注册会拿到已释放内存，大概率崩溃或乱码，必须真跑验证）。
- 观察 RSS（可选）：Activity Monitor 或 `ps -o rss`，任务二完成后稳态 RSS 应比之前低 ~20MB。
