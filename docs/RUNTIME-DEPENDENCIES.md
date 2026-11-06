# LongCut 运行时依赖与本地启动说明

> 适用产物：`src/target-gnu/x86_64-pc-windows-gnu/app/longcut.exe`
> （windows-gnu / `--profile app`：release + fat LTO + panic=abort + strip=symbols）
> 便携包：`dist/LongCut-win64-gnu/`（exe + 全部非系统 DLL + 合规文件，可整体搬移）
> 安装包：`dist/LongCut-0.2.10-win64-gnu.msi`（WiX 4，按机器安装）
> 状态：**本机自用 / 便携包 / .msi 均已实测可运行**；未做代码签名。审查结论见 `docs/REVIEW-2026-11-06.md`。

## 1. 启动方式（唯一推荐）

```
tools\run-longcut.bat --version
tools\run-longcut.bat --smoke
tools\run-longcut.bat --mcp
```

`run-longcut.bat` 会：从脚本自身位置推导项目根目录 → 读取 `tools/ffmpeg/FFMPEG_DIR.txt`
定位 FFmpeg → 把 FFmpeg `bin` 与 MinGW `bin` 加进 `PATH` → 透传全部参数启动 exe。
项目根目录不再硬编码在 bat 里。启动器默认优先选 `app` profile 的 strip 产物，
不存在时才回退 `debug`；也可用 `LONGCUT_PROFILE_DIR` 显式指定。

> Git Bash 里**直接**执行 exe 会返回 127（MSYS 对 GUI 子系统程序的处理差异），
> 不是产物损坏；走 bat 或 Windows 原生 `Start-Process` 均返回 0。

### 1.1 便携包（推荐给「换台电脑直接用」）

```
LONGCUT_PROFILE_DIR=app bash tools/stage-portable.sh   # 组装 dist/LongCut-win64-gnu/
dist\LongCut-win64-gnu\run-longcut.bat --version
```

`stage-portable.sh` 把 exe、11 个非系统 DLL、`LICENSE` / `THIRD_PARTY_NOTICES.md` /
`BUILD_INFO.txt` / `RUNTIME-DEPENDENCIES.md` / `README.txt` / 启动器拷进同一目录，
逐项校验文件非空。启动器把 PATH 收窄成「本目录 + Windows 自身目录」——
实测 `--version` / `--smoke` / `--whisper-cpu` 全部 `RC=0`，证明 DLL 收齐、
不依赖开发机 PATH。目录内无绝对路径，可整体拷贝到任意位置。

## 2. 动态库依赖（objdump 实测）

exe 的导入表共 43 项 DLL，其中 **32 项是 Windows 系统库 / UCRT**（`KERNEL32`、
`api-ms-win-crt-*` 等），真正需要额外提供的只有 11 个：

| 类别 | DLL | 来源 |
|---|---|---|
| FFmpeg（7） | `avcodec-63.dll`、`avdevice-63.dll`、`avfilter-12.dll`、`avformat-63.dll`、`avutil-61.dll`、`swresample-7.dll`、`swscale-10.dll` | `tools/ffmpeg/ffmpeg-master-latest-win64-gpl-shared/bin` |
| MinGW 运行时（4） | `libstdc++-6.dll`、`libgcc_s_seh-1.dll`、`libwinpthread-1.dll`、`libgomp-1.dll` | `tools/mingw/mingw64/bin` |
| ONNX Runtime（可选） | `onnxruntime.dll` | **未随产物提供**。`ort` 以 `load-dynamic` 方式加载，仅供 AI 抠像/切图使用；缺失时这些功能降级，普通剪辑不受影响 |
| 系统 / UCRT（32） | `KERNEL32`、`USER32`、`dwrite`、`dxgi`、`opengl32`、`api-ms-win-crt-*` 等 | Windows 10+ 自带；Win7 SP1 需另装 UCRT 运行库 |

FFmpeg 与 MinGW DLL 的传递依赖已核对：`libstdc++-6.dll → libgcc_s_seh-1.dll →
libwinpthread-1.dll` 成链，FFmpeg 各 DLL 之间互相引用（故 7 个全收），
除此之外只剩 Windows 系统库。因此**裸 exe 不可分发**：要么通过 bat 注入 PATH，
要么用 `tools/stage-portable.sh` 把这 11 个 DLL 复制到 exe 同目录。

## 3. 随产物提供的合规文件

- `LICENSE` —— AGPL-3.0-or-later（上游 Concat 许可证，已复制到 exe 同目录）
- `THIRD_PARTY_NOTICES.md` —— 第三方组件署名与许可说明（已复制到 exe 同目录）
- `BUILD_INFO.txt` —— 由 `tools/build-gnu.sh` 在构建成功后写入，含产品名、版本、UTC 构建时间、rustc 版本、toolchain、target、profile

> Slint 以 GPL-3.0-only 选项引入，与 AGPL 引擎并存的合规说明见根目录
> `LICENSING.md` 与 `THIRD_PARTY_NOTICES.md`。正式分发前还应核对 FFmpeg（GPL）
> 构建对应的源码提供义务。

## 4. 已知取舍（不是 bug）

- **软件渲染器**：windows-gnu 缺 Skia 预编译包，桌面端改用 Slint `renderer-software`；
  iOS / Android 目标仍启用 Skia。恢复 MSVC 工具链后可取消
  `src/crates/concat/Cargo.toml` 中 `"renderer-skia"` 的注释。
- **release 产物**：`--profile app` 已启用 fat LTO / `panic=abort` / `strip=symbols`，
  调试符号全部去掉：`longcut.exe` 为 84,113,408 B（约 80.2 MiB），
  相比 dev/debug 版 1,867,690,428 B（约 1.78 GiB）缩小 95.5%；
  便携目录合计 268 MB，`.msi` 为 98,553,856 B（约 94 MiB）。
- **构建溯源**：本工作区无 `.git`，`BUILD_INFO.txt` 的 `commit` 记为 `local`。

## 5. 发布流水线状态（2026-11-06）

| # | 事项 | 状态 |
|---|---|---|
| 1 | `--profile app` 重建并 strip | ✅ 已产出 `app/longcut.exe`，`BUILD_INFO.txt` 记录 `profile=app` |
| 2 | FFmpeg / MinGW 运行时 DLL 收集 | ✅ `tools/stage-portable.sh` → `dist/LongCut-win64-gnu/`（18 个文件） |
| 3 | 安装包 | ✅ `.msi` 由 WiX 4.0.5（`tools/build-installer.ps1`）生成；Inno Setup 的 `setup.exe` 需本机装 `ISCC.exe`（`-Inno` 参数） |
| 4 | 干净 PATH 验证 | ✅ `scripts/ci/smoke-windows.ps1` 已兼容 PS 5.1（dumpbin 缺失时回退 MinGW objdump），12 个 PE 的导入表 + 三项冒烟全过 |
| 5 | 版本递增 | ✅ `0.2.9 → 0.2.10`，同步 `src/Cargo.toml` / `Cargo.lock` / `--version` / 安装包 `Version` / `README.txt` / `concat.iss` / `concat.wxs` |
| 6 | CI lane 首跑 | 🟡 `.github/workflows/longcut-windows-gnu.yml` 已对齐 app profile 与 MSI 归档，但本机无 `.git`/Actions，GH-hosted runner 尚未实测 |
| 7 | 代码签名 | 🟡 未做；SmartScreen 对未签名 exe 可能提示风险 |
