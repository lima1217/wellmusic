# Ticket 1：进度条定时器状态机修复（armed 入 Model + rejected 降级 + 测试）

优先级：高（唯一有真实缺陷风险的一张）
预估：2–4 小时
背景文档：`docs/code-review-spec.md` 第 B1、B2、O5 节（本票自包含，不读也能做）

## 背景

本项目是 Zig 写的 macOS 音乐库应用（TEA 架构：`Model` + `Msg` + `update` + effects）。
最近的改动把播放进度条的时钟从 GPU 逐帧 present 循环改成了 ~20 Hz 的 fx 定时器：

- `src/model.zig` 约 367 行：`scrubber_timer_key = 42`、`scrubber_interval_ms = 50`。
- `src/model.zig` 约 2693 行：`syncScrubberTimer(model, fx)` —— 由 `update` 的第一行 `defer` 在每条消息后调用，按 `want = model.playing and model.now != null and !model.buffering` 的边沿启停定时器。
- `src/model.zig` 约 2331 行：`.scrubber_tick` 消息分支，调 `advanceRenderedClock` 前进渲染时钟。

SDK 语义（`/opt/homebrew/lib/node_modules/@native-sdk/cli/src/runtime/effects.zig`，只读参考，不要改 SDK）：

- `fx.startTimer` 同 key 是**替换**语义：对已激活的 key 再次 start 会重置间隔（所以才需要边沿触发，不能每次 update 都 start，否则永远不 fire）。
- 定时器可能被**拒绝**（timer 表满 16 个、interval 为 0、平台无 timer 服务）：拒绝不静默，会投递恰好一条 `outcome == .rejected` 的 `EffectTimer` 消息。
- fake executor（测试用）的 `fireTimer` 投递 `timestamp_ns = 0` 的 fired 消息。

## 缺陷一（B1）：armed 标志是模块级全局变量

`src/model.zig` 约 373 行：

```zig
var scrubber_timer_armed: bool = false;
```

这不在 `Model` 里，跨 Model 实例泄漏：

- 测试 A 在播放态结束（armed 残留 true），测试 B 新建 Model 播放时 `want == armed` 成立，`startTimer` 被静默跳过。
- Journal replay 用 fresh Model 但全局残留，重放的效果序列和原始运行不一致，违反本项目的确定性契约（工程内注释多处强调 "deterministic-init"）。

**修复要求**：把该标志改为 `Model` 的字段（如 `scrubber_timer_armed: bool = false`）。注意：

- `Model` 有一个 `view_unbound` 声明列表（约 700 行起），列出不被 markup 绑定的字段以通过 `native check` 的 dead-state lint —— 新字段必须加进去。
- 删除模块级 `var`，`syncScrubberTimer` 改读写 `model.scrubber_timer_armed`。

## 缺陷二（B2）：定时器被 reject 后永久失联

`.scrubber_tick` 分支当前是：

```zig
.scrubber_tick => |timer| {
    if (timer.outcome != .fired) return;
    ...
},
```

rejected 被静默吞掉，而 armed 仍为 true → 之后每次 update 里 `want == armed` 恒成立，**永远不重试**。平滑进度条静默死亡（只剩 ~500ms 一次的音频 position tick 粗粒度前进），用户暂停再播放才能恢复。

**注意陷阱**：不能简单地在 rejected 时把 armed 置回 false 完事——update 末尾的 defer sync 会立刻重试 startTimer，在永久拒绝的主机上形成 reject → retry → reject 的无限消息循环。

**修复要求**（按此设计，除非你发现更好的且写明理由）：

1. `Model` 增加 `scrubber_degraded: bool = false`（同样加入 `view_unbound`）。
2. `.scrubber_tick` 收到 `outcome == .rejected` 时：`model.scrubber_timer_armed = false; model.scrubber_degraded = true;`。
3. `syncScrubberTimer` 中：`want` 为 true 但 `scrubber_degraded` 为 true 时不再 start（本次播放会话内放弃，靠 position tick 降级运行）。
4. `want` 变为 false 的边沿（暂停/停止/缓冲）同时清掉 `scrubber_degraded` —— 这样下一次播放会重试一次，每个播放会话至多一次 reject，不会循环。

## 测试要求（当前这条路径完全没有覆盖）

测试写在 `src/tests.zig`，参考现有的 `apply()` 辅助（fake Effects 逐消息）和 `LiveApp` 辅助（完整 harness，能摸到 `app_state.effects`）。fake executor 下 `startTimer` 会把 slot 记入 Effects 的 timer 表（见 SDK `effects.zig` 的 `startTimer`：fake 路径设置 slot 后直接 return）——用它断言定时器是否激活；如 Effects 没有公开查询接口，断言其公开字段或用 `LiveApp` 派发真实消息链。

至少覆盖：

1. play 一条 track 后 scrubber 定时器已启动；pause 后取消；`.audio_event .failed` 后取消。
2. `.scrubber_tick`（fired，timestamp 0）使 `elapsed_ms` 前进 50ms。
3. **跨 Model 隔离**：连续两个独立 Model 各自 play，断言第二个也发出了 startTimer。（在修复前这条应当是红的——先写它验证复现，再修。）
4. rejected 降级：注入 `outcome == .rejected` 的 `.scrubber_tick` 后，后续 update 不再重复 startTimer；暂停再播放后会重试。

## 验收

- `native test` 全绿（当前基线 33/33，本票会新增若干条）。
- `native check` 通过（`view_unbound` 列表更新正确）。
- 模块级 `var scrubber_timer_armed` 已删除，grep 不到容器级可变状态。
- 不改动本票范围外的行为（`advanceRenderedClock` 的 clamp 逻辑、`frame_clock` 消息的兼容路径都保持原样）。
