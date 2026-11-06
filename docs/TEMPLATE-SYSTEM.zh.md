# 龙儿剪辑 LongCut · 模板 / 一键成片 系统设计（v1 设计稿）

> 状态：**设计阶段（先方案后编码）**。本文是「龙儿自用版」相对上游 Concat 唯一需**新建**的能力模块（剪映有、Concat 无）。
> 全文基于 Concat v0.2.9 真实数据结构，可直接作为后续实现规格。

## 1. 背景与目标

| 项 | 说明 |
|---|---|
| 现状 | Concat 已有完整的工程模型（Project / Timeline / Track / Clip）与命令式编辑接口（`Editor::apply(Command)`），但**没有"模板"概念**——每次成片都从空白工程开始手动拼。 |
| 剪映差异 | 剪映的核心体验之一是「模板 + 一键成片」：用户丢一堆素材，系统按模板自动套用转场/特效/字幕/卡点，秒出片。这是龙儿自用版要补的差异化能力。 |
| 目标 | 在 Concat 引擎之上，零侵入（不改内部 crate 名、不改渲染/合成逻辑）地新增**模板系统**与**一键成片（AutoCut）**两条能力，复用现有 `Editor` 命令接口完成实例化。 |
| 红线 | 不反编译、不抄袭剪映代码；模板是「数据 + 实例化逻辑」，全部自研。 |

## 2. Concat 现有能力（复用点）

`src/crates/concat-project/src/model.rs` 已提供：

- `Project { media: Vec<MediaItem>, timelines: Vec<Arc<Timeline>>, active_timeline_id }`
- `Timeline { video: VideoSettings, tracks: Vec<Track>, clips: Vec<Arc<Clip>>, linkage }`
- `Track { id, visible, muted }`
- `Clip { id, track_id, media_id, kind, start, duration, source_start, volume, fade_in/out, scale, offset_x/y, rotation, stretch_x/y, opacity, speed, speed_curve, keys: Vec<ClipKey>, flip_h/v, blend, crop, cutout, mask, filters: Vec<AppliedFilter>, transition_in: Option<Transition>, text: Option<TextStyle>, … }`
- `Editor::apply(Command)` 命令集（部分）：`AddMedia`、`AddClip`、`AddClipAtFirstFree`、`AddClipsInSequence`、`AddTransitionClip`、`SetClipTransform`、`SetClipKey`、`SetClipCutout`、`SetClipSpeedCurve`、`SetClipEnhanced`、`SetClipText`…

**结论**：模板实例化 = 把「模板蓝图」翻译成一串 `Command` 施加到一个新 `Editor` 上。无需改动渲染层。

## 3. 数据模型

### 3.1 模板清单 `TemplateManifest`
```jsonc
{
  "id": "basic-opener",
  "name": "基础开场",
  "version": "1.0.0",
  "author": "longcut",
  "description": "一段主视频 + 可选照片 + 背景音乐 + 标题",
  "tags": ["opener", "vlog"],
  "aspect": "16:9",            // 16:9 | 9:16 | 1:1 | 4:3
  "defaultDuration": 10.0,
  "minClipping": 0.0,
  "slots": [ /* 见 3.2 */ ]
}
```

### 3.2 槽位 `TemplateSlot`
模板里的「占位符」，实例化时被用户素材/文本填充。
```jsonc
{
  "id": "main_video",
  "role": "main_video",        // main_video | secondary_video | photo | music | sfx | title_text | subtitle | logo | overlay
  "accepts": ["video"],        // 来自 MediaKind: video | image | audio | text(由用户键入)
  "min": 1, "max": 1,
  "preferredDuration": 8.0,
  "beatSync": false,           // 是否卡点（需要节奏分析）
  "kenBurns": false,           // 照片是否推拉摇移
  "placeholder": "{{title}}"   // 仅 text 类槽位：默认文本模板
}
```

### 3.3 蓝图 `TemplateBlueprint`
一份「带槽位引用的半成品工程」，字段直接对应 Concat 的 `Timeline/Clip`。
- 轨道（tracks）与平面 Concat `Track` 一致。
- 片段（clips）在普通 `Clip` 字段之外，用 `slot` 字段引用某个 `TemplateSlot` 的 `id` 取代具体 `media_id`；并允许用占位表达式：
  - `{{slot.<id>.duration}}` → 绑定素材的实际时长
  - `{{prev.end}}` → 上一个同轨片段结束时间（自动接续）
  - `{{title}}` → 文本槽位的用户输入
- 片段可携带 `filters`（特效/滤镜）、`transition_in/out`、`keys`（关键帧）、`text`（字幕样式），全部沿用 `AppliedFilter` / `Transition` / `ClipKey` / `TextStyle` 结构。

### 3.4 文件与目录约定
```
assets/templates/
  schema/template.manifest.schema.json   # 清单 JSON Schema（校验用）
  samples/
    basic-opener/template.json           # 样例模板（见附录 A）
    travel-recap/template.json
  library.json                           # 已安装模板索引（id → 路径/缩略图）
```
上述 schema、两个样例与 library.json 均已落盘（2026-11-06）。
模板以 JSON 存储，可热加载，无需重编译。**注意：本模块目前仍为设计稿 + 数据文件，
`concat-templates` crate 与 CLI/MCP/UI 接入尚未实现**；`src/` 中没有任何对
`assets/templates` 的引用，运行时不会加载这些文件。

## 4. 实例化管线（核心逻辑）

```
用户选模板 + 提供素材集(文件或已导入 media_id)
        │
   [1] validate   校验槽位约束(min/max/accepts/aspect)
        │
   [2] bind       把素材映射到 slot（照片多张→多实例；文本→填入 placeholder）
        │
   [3] instantiate 对新建 Editor 施放 Command 序列：
        │    AddMedia(item)* → AddClip/AddClipsInSequence（按 slot 蓝图）
        │    → SetClipTransform / SetClipKey / SetClipCutout
        │    → AddTransitionClip / SetClipText（解析占位表达式）
        │    → 时间轴收尾（linkage、背景）
        │
   [4] resolve     生成最终 Project 文档（to_document），返回给 UI 打开 / 直接导出
```

占位表达式在 `[3]` 阶段由 `TemplateEngine` 求值：先收集每个 slot 绑定素材的时长/文本，再按拓扑顺序替换 `{{prev.end}}` 等相对引用。

### 4.1 边界与校验规则（M1 实现规格）

JSON Schema 只约束单字段；**跨字段与运行时边界由 `TemplateEngine::validate()` 负责**：

| 规则 | 期望行为 |
|---|---|
| `slot.min <= 绑定素材数 <= slot.max` | 不满足则拒绝实例化，错误里带 slot id / 期望 / 实际 |
| `max >= min` 且 `max >= 1` | 清单加载时校验；`max = 0` 视为禁用槽位 |
| `rateDen > 0`、`width/height > 0` | Schema 已设 `minimum: 1`；引擎再做一次防御性断言，杜绝除零 |
| `aspect` 与 `video.width/height` | 允许 ±1 像素舍入；不一致时告警但不阻断（竖屏裁剪、30000/1001 帧率常见） |
| `{{prev.end}}` | 取**同轨**上一个已解析片段的 `start + duration`；该轨道尚无前驱时取 `0`，不报错。`basic-opener` / `travel-recap` 的 photo clip 都走这条规则 |
| 多素材槽位（如 `photo.max=3`） | 蓝图里的一条 clip 视为「实例模板」：按绑定素材数复制 N 份，按素材顺序依次设 `start = 上一段 end`、`duration = 该素材实际时长`，`kenBurns`/滤镜字段逐份继承 |
| 未解析的占位符 | 实例化失败并列出未解析 token，**禁止**把 `{{...}}` 原样写进时间轴 |
| `clip.track` / `clip.slot` 引用 | 必须能在 `tracks` / `slots` 中解析到，否则报错 |
| 空输入 | 素材集为空且所有槽位 `min = 0` 时，返回明确拒绝，不生成空工程 |

> 错误处理约定：任何校验失败返回 `TemplateError`（含模板 id、slot/字段名、期望值、实际值），
> 不 panic、不静默降级 —— 一键成片必须能告诉用户「哪一步、哪个槽位」出了错。

## 5. 一键成片 AutoCut（进阶）

在模板实例化之上加一个「智能选择 + 绑定」层：

1. **分析** `analyze(media_set)`：分类（视频/照片/音频）、取时长、可选轻量分析（人脸/场景/响度，借 `concat-vision` / `concat-speech` 的离线模型，可选）。
2. **选模板** `select_template(analysis, library)`：按槽位匹配度打分（素材计数 vs min/max、时长 vs preferredDuration、纵横比），返回 Top-3，用户可改。
3. **自动绑定** `auto_bind`：最长视频→main_video；照片→photo 槽位（启用 Ken Burns）；音频→music 槽位；按文件名/时间排序；可选卡点（beatSync 模板）。
4. **实例化 + 导出**：走第 4 节管线，再调 `concat-export` 出片（H.264/HEVC/AV1，最高 4K60）。

## 6. 集成点（落地位置）

| 集成点 | 形式 | 说明 |
|---|---|---|
| 新 crate `concat-templates` | Rust 库 | 提供 `TemplateManifest`/`TemplateSlot`/`TemplateBlueprint` 解析、校验、`TemplateEngine::instantiate()`。纯数据+命令翻译，**不依赖 GPU**，可单测。 |
| `concat-cli` | 子命令 | `longcut template list` / `template apply --template X --media a.mp4 b.jpg --out proj.longcut`；`longcut autocut --dir ./素材 --out out.mp4`。 |
| `concat-mcp` | MCP 工具 | 暴露 `apply_template` / `autocut`，让 AI（含龙儿）可直接驱动「给我用 travel-recap 模板把这批素材剪成片」。与现有 `concat --mcp` 天然契合。 |
| `concat`（UI） | Slint 面板 | 启动页/工程页新增「模板 / 一键成片」入口：模板浏览卡 + 拖入素材 + 一键生成。UI 工作量最大，建议放最后。 |

> `concat-templates` 作为**独立 workspace 成员**加入 `src/Cargo.toml` 的 `members`，但**不**强制 `longcut` 依赖它（CLI/MCP 才依赖），避免拖慢主程序编译与本次构建验证。

## 7. 里程碑

| 阶段 | 内容 | 产出 | 是否阻塞本次构建 |
|---|---|---|---|
| M1 | 数据模型 + JSON Schema + 样例模板 + 解析/校验 | `concat-templates` 骨架 + `samples/*` | 否（独立 crate） |
| M2 | `TemplateEngine::instantiate()` 命令翻译 | 单元测试（用 `Editor` round-trip 校验） | 否 |
| M3 | AutoCut 分析/选择/绑定 | CLI `autocut` 可用 | 否 |
| M4 | UI 面板（模板浏览 + 拖拽成片） | Slint 界面 | 否 |
| M5 | MCP 工具接入 | `concat-mcp` 扩展 | 否 |

## 8. 下一步（待老板拍板后进入编码）

1. 先实现 **M1+M2**（纯逻辑、可单测、不影响主构建），产出可跑的 `concat-templates` crate。
2. 再接 **M3 CLI**，让你能 `longcut template apply` 验证效果。
3. M4/M5 视体验再排期。

---

## 附录 A — 样例模板 `assets/templates/samples/basic-opener/template.json`

```json
{
  "manifest": {
    "id": "basic-opener",
    "name": "基础开场",
    "version": "1.0.0",
    "author": "longcut",
    "description": "主视频 + 可选照片推拉 + 背景音乐 + 标题",
    "tags": ["opener", "vlog"],
    "aspect": "16:9",
    "defaultDuration": 10.0,
    "slots": [
      {"id":"main_video","role":"main_video","accepts":["video"],"min":1,"max":1,"preferredDuration":8.0},
      {"id":"photo","role":"photo","accepts":["image"],"min":0,"max":3,"preferredDuration":2.0,"kenBurns":true},
      {"id":"music","role":"music","accepts":["audio"],"min":0,"max":1},
      {"id":"title","role":"title_text","accepts":["text"],"min":0,"max":1,"placeholder":"{{title}}"}
    ]
  },
  "blueprint": {
    "video": {"width":1920,"height":1080,"rateNum":30000,"rateDen":1001},
    "tracks": [
      {"id":"T1","kind":"video"},
      {"id":"T2","kind":"video"},
      {"id":"T3","kind":"audio"}
    ],
    "clips": [
      {"slot":"main_video","track":"T1","start":0,"duration":"{{slot.main_video.duration}}",
       "scale":1.05,"filters":[{"id":"gaussian_blur","params":{"radius":1.5}}],
       "transition_in":{"id":"fade","duration":1.0}},
      {"slot":"photo","track":"T2","start":"{{prev.end}}","duration":"{{slot.photo.duration}}","kenBurns":true,"opacity":0.9},
      {"slot":"music","track":"T3","start":0,"duration":"{{slot.music.duration}}","volume":0.6},
      {"slot":"title","track":"T2","start":1.0,"duration":3.0,"text":"{{title}}",
       "textStyle":{"size":72,"align":"center","color":"#ffffff"}}
    ]
  }
}
```

## 附录 B — 设计要点小结

- **零侵入**：只新增 `concat-templates` crate + CLI/MCP/UI 接入，不碰 `concat-render`/`concat-effects` 等核心。
- **数据驱动**：模板即 JSON，热加载，易扩充；龙儿自用模板可自己攒一套放 `assets/templates/samples`。
- **复用命令接口**：实例化完全走 `Editor::apply(Command)`，与手动编辑同一条代码路径，行为一致、易测。
- **AI 友好**：MCP 暴露后，龙儿可直接说「用 XX 模板把这批素材剪了」，闭环到本次「龙儿自用版」定位。
