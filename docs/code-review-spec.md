# 代码审查 Spec — 20 Hz 进度条定时器 + CJK 字体注册

日期：2026-07-21
范围：本次未提交改动（`src/main.zig`、`src/model.zig`、`src/theme.zig`、新增 `src/ui_font.zig`），以及与之交互的 `src/media_session.zig`。
现状：`native test` 33/33 通过；改动整体设计合理（播放时钟从 display-rate present 循环降到 ~20 Hz fx 定时器，注册系统 CJK 字体消除 tofu）。以下为发现的问题与优化项，按严重程度排列。**本文档只描述，不改代码。**

---

## 一、Bug / 正确性风险

### B1（中）`scrubber_timer_armed` 是容器级全局变量，不属于 Model

位置：`src/model.zig:373`（`var scrubber_timer_armed: bool = false;`）

问题：armed 标志跨 Model 实例、跨 App 生命周期泄漏，违反本项目自己反复强调的确定性契约（"no env read ever happens inside update"、replay 的 deterministic-init）：

- **测试顺序依赖**：`tests.zig` 里多个测试各自创建新 `Model` 并通过 `apply()`/`LiveApp.dispatch()` 走 update。前一个测试在 `playing == true` 状态下结束（如 "play mode cycles…"），全局 armed 残留为 true；下一个测试播放时 `want == armed`，`fx.startTimer` 被跳过。今天没有测试断言定时器状态所以全绿，但这是一颗顺序敏感的地雷（见 O5 的测试缺口）。
- **Journal replay**：fresh Model + 残留 armed=true → 重放时不再发出 startTimer 效果，与原始运行的效果序列不一致。
- **一进程多 App**：`LiveApp` 的 start/stop、embed 场景下 App 重建，全局标志都不会复位。

建议方向：把标志移进 `Model`（加入 `view_unbound` 列表），或至少在 `boot`/`init_fx` 里显式复位。存进 Model 后 replay 也自然正确。

### B2（中）定时器被 reject 后 armed 标志与真实状态永久失联

位置：`src/model.zig:2331-2337`（`.scrubber_tick` 分支）+ `syncScrubberTimer`

问题：SDK 的 `startTimer` 被拒绝时（timer 表满 16 个、平台无 timer 服务）会投递一条 `outcome == .rejected` 的 Msg。当前处理是 `if (timer.outcome != .fired) return;` —— 静默吞掉。此时 `scrubber_timer_armed == true` 但平台上没有任何定时器在跑；之后每次 update 里 `want == armed` 恒成立，**永远不会重试**。结果：平滑进度条静默死亡，只剩 ~500ms 一次的 position tick 粗粒度前进，且暂停/播放一次即可恢复——典型的"偶发、难复现"类缺陷。

注意：不能简单地在 rejected 时把 armed 置回 false —— defer 里的 sync 会立刻重试 startTimer，在永久拒绝的主机上形成 reject → retry 的无限 Msg 循环。建议方向：rejected 时 disarm 并置一个 `scrubber_degraded` 标志（有意识地降级、不再重试），或允许有限次数重试。至少应加注释说明当前"放弃"是有意行为。

### B3（低）`media_session.poll()` 是死代码，`onFrame` 的注释在撒谎

位置：`src/media_session.zig:26,45-53`；`src/main.zig:283-290`

问题：`pending` 这个原子变量**全工程没有任何写入路径**（模块头注释也承认 remote-command target 有意未接——`addTarget:action:` 的 ABI 太脆）。`poll()` 永远返回 `.none`，`onFrame` 里整个 `switch (media_session.poll())` 块是死分支，注释却声称 "drain macOS remote-command buttons"。本次 diff 还把这个死分支从无条件挪到了 playing 门控内——挪了一段永远不执行的代码。

建议方向：二选一——(a) 删除 `poll()`/`pending` 通道和 `onFrame` 里的 drain 块，注释改为如实描述（远程命令走状态栏菜单和焦点媒体键）；(b) 真正接上 MPRemoteCommandCenter（需要真 ObjC bridge）。当前状态最差：代码在、注释错、功能无。

### B4（低）Now Playing publish 无节流、无 autoreleasepool

位置：`src/main.zig:322-333`（`animations()` 里的 `media_session.publish`）；`src/media_session.zig:156-189`

问题（先于本次改动存在，但值得记录）：

- `animations()` 每次 rebuild 都跑，播放时 = 每个 scrubber tick ≈ 20 Hz。每次 publish 创建 NSMutableDictionary/NSString/NSNumber（全部 autoreleased）并调 `setNowPlayingInfo:`。若所在线程没有 autorelease pool 在转，这些对象会堆积；即使有，20 Hz 的 IPC 调用喂 Now Playing 也纯属浪费——系统用 elapsed + rate 自己外推进度。
- `lookupCfString` 每次 publish 都做 5 次 dlsym。

（对比之前的 display-rate present 循环这其实已经是改善，但既然定时器改造的目的就是省电，这里是下一个热点。）

建议方向：按内容变化节流——仅当 track id、playing 标志或 elapsed 秒数变化时 publish；CFString key 查一次缓存；publish 内包 `objc_autoreleasePoolPush/Pop`（同样可 dlsym）。

### B5（低）`nsString` 512 字节截断可能切断 UTF-8 序列

位置：`src/media_session.zig:141-148`

问题：`@min(bytes.len, buf.len - 1)` 按字节截断。CJK 标题 3 字节/字，截在多字节序列中间 → 非法 UTF-8 → `stringWithUTF8String:` 返回 nil → 标题静默不显示。本次改动的主题正是 CJK 支持，这个边界更值得修。建议：截断时回退到最近的 UTF-8 序列边界（`std.unicode` 可判定），或干脆放大缓冲。

---

## 二、已确认无问题的点（审查记录）

- `update` 的 `defer syncScrubberTimer(...)` 覆盖所有 return 路径，含 `.scrubber_tick` 分支的早退和 `.media_command` 的递归 update（幂等，重复跑无害）。
- SDK `startTimer` 同 key 是**替换**语义（`effects.zig` 文档），所以 buffering 抖动导致的 start/cancel 往复只是平台定时器重建开销，不会丢 fire 也不会重复。
- `advanceRenderedClock` 对 timer 路径传 `interval_ns = 50ms`，delta clamp 到 4×interval = 200ms：暂停恢复、遮挡合并唤醒都只会温和步进；fake executor 的 `timestamp_ns = 0` 走 `<= last` 分支按固定 interval 前进，测试可复现。
- `ui_font.load` 的 `Face.parse` 预检**覆盖 glyph 预算门**（SDK 的 `FontGlyphTooComplex` 就产自 parse），所以不会出现"预检通过、installing frame 注册失败导致 app 启动报错"的路径；`allocRemaining(.limited(24MiB))` 与 `canvas_limits.max_registered_canvas_font_bytes` 相等，超限文件读取即报错跳过。
- `theme.light_colors/dark_colors` 的 comptime 复制目前与 `tokens()` 等价（`ThemeOptions` 默认 `contrast=.standard, reduce_motion=false`）——但见 O1 的 drift 风险。
- 三个入口（`main`、`initModel`、测试 harness）中，凡调用 `wellMusicOptions()/mobileOptions()` 之前 `prepareUiFonts()` 均已执行或有意未执行（测试不加载字体，`fonts` 切片为空，行为一致）。
- `stopAtEnd`、`.failed` 清理、暂停等所有 `playing/buffering/now` 变化路径都经 update → defer sync，armed 与期望状态同步（B1/B2 的全局性问题除外）。

---

## 三、优化建议

### O1 theme.zig：消除三份重复的 ThemeOptions/overrides

`tokens()`、`light_colors`、`dark_colors` 现在各写一遍 `.pack = .geist` + `accentOverridesFor(...)`。改成一个**纯函数** `fn standardTokens(scheme: canvas.ColorScheme) canvas.DesignTokens`（comptime 可求值），`tokens()` 在其上包 `withUiFont`，导出的 colors 直接取 `standardTokens(.light).colors`。当前正确性依赖"ThemeOptions 默认值恰好等于 tokens() 显式传的值"，将来任何一处改 pack/contrast 都会静默 drift，而测试只比对 colors，typography/motion 的 drift 抓不到。

### O2 字体字节双份常驻（~46 MB RSS）

SDK 在注册时**复制**字体字节（`FontRegistration.ttf`："Copied at registration"），而 `ui_font.loaded_bytes` 永久持有原始 ~23 MB。注册发生在 installing frame，之后 app 侧的副本就没用了（`withUiFont` 只读 `ready()` 标志和 `font_id`）。建议：首帧之后释放 `loaded_bytes`（保留一个 `registered` 布尔取代 `ready()` 的 len 判断），把常驻成本减半。注意释放时机必须在 installing frame 完成之后，`on_frame` 首次回调是现成的锚点。

### O3 `readAbsolute` 的增长式读取

`allocRemaining` 对 23 MB 文件在 page_allocator 上反复 realloc+copy。先 `stat` 拿文件大小、一次性精确分配再读满即可。一次性启动成本，优先级低，但顺手。

### O4 `max_font_bytes` 硬编码

`ui_font.zig:29` 手写 `24 * 1024 * 1024` 并靠注释"Keep in lockstep"。若 `native_sdk` 根导出了 `canvas_limits.max_registered_canvas_font_bytes`（SDK 内部有此常量），直接引用；未导出则建议给 SDK 提需求，短期保留注释。

### O5 测试缺口（本次改动的核心路径全部无测试）

建议补：

1. **定时器生命周期**：play → fake Effects 里 scrubber timer active；pause/`.failed`/`stopAtEnd` → cancel；`.scrubber_tick`（fired）→ `elapsed_ms` 前进 50ms；rejected → 按 B2 决定的降级行为断言。`LiveApp` 已经能摸到 `app_state.effects`。
2. **跨 Model 隔离**：连续两个 Model 各自 play，断言第二个也发出了 startTimer——这条测试今天就会暴露 B1。
3. **字体回退**：`ui_font.load` 找不到候选文件时 `ready() == false` 且 `theme.tokens` 的 `typography.font_id` 保持 pack 默认；加载成功时 high-contrast 路径也带上 `font_id`（当前 `withUiFont` 的 high-contrast 行为是新语义，值得钉住）。

### O6 mobile/iOS 路径的字体预期

`initModel()` 也调 `prepareUiFonts()`，但两个候选路径都是 macOS 专属——iOS 上必然静默失败，CJK 回到 tofu。`app.zon` 目前 `platforms = macos`，无实际影响；建议在 `ui_font.zig` 模块注释里写明"macOS-only，phone 目标需另配候选路径或打包字体"，防止将来开 iOS 时误以为已覆盖。

### O7 备忘：`withUiFont` 未覆盖 `mono_font_id`

等宽槽（时间戳、数字）仍是 Geist Mono。当前没有 CJK 文本走 mono 槽，无实际问题；若将来在 mono 上下文渲染标题需同步覆盖。

---

## 四、建议的处理顺序

1. B1 + B2（同一处状态机，一起修：armed 入 Model + rejected 降级策略）+ O5.1/O5.2 的配套测试。
2. B3（删死代码与错误注释，五分钟的事）。
3. O1（theme 去重，纯重构，测试已覆盖 colors）。
4. O2（内存减半）；B4/B5、O3/O4 随手顺带。
