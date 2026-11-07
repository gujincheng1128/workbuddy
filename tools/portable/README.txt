龙儿剪辑 LongCut 0.2.11  —  便携包（Windows x86_64 / windows-gnu / --profile app）
========================================================================

[这是什么]
以 Concat (AGPL-3.0) 为基石的「龙儿自用版」视频编辑器。本目录是「解压即用」
的便携形态：可执行程序、全部非系统运行时 DLL、许可证与构建溯源信息都在同一
层目录，不含任何绝对路径，整体可以拷到任意目录或 U 盘。

本包是 --profile app 的正式构建：继承 release 的 opt-level=3 / codegen-units=1，
并把 LTO 从 thin 提升为 fat，再加 panic=abort 与 strip=symbols，已去掉调试符号。
exe 由早期 dev/debug 版的 1,867,690,428 B（约 1.78 GiB）缩小到 84,113,408 B
（约 80.2 MiB），仅为原来的 4.5%；整个便携目录 268 MB。

[怎么运行]
  run-longcut.bat --version      查看版本
  run-longcut.bat --smoke        启动自检
  run-longcut.bat --whisper-cpu  查看 Whisper CPU 后端
  直接双击 longcut.exe           打开编辑器窗口（GUI，无控制台输出）

run-longcut.bat 会把 PATH 收窄成「本目录 + Windows 自身目录」，用来证明
DLL 收齐了；日常使用也可以直接把本目录加进 PATH 后运行 longcut.exe。

[安装包]
  dist/LongCut-0.2.11-win64-gnu.msi 为 WiX 4 生成的按机器安装包
  （Program Files\LongCut + 开始菜单 + 干净卸载），内容与本便携目录一致。
  Inno Setup 的 setup.exe 需本机装 ISCC.exe 后才能生成，见
  tools/build-installer.ps1 的 -Inno 参数。

[运行环境]
  - Windows 10 / 11 x64（UCRT 由系统提供）。
  - Windows 7 SP1 需要另装 UCRT 运行库：FFmpeg 的 DLL 依赖
    api-ms-win-crt-*.dll 系列；本包不含这些系统组件。
  - 本构建使用 Slint 软件渲染器（renderer-software），不要求特定 GPU；
    --software / --smoke 均正常，不再出现 "unrecognized renderer" 警告。
  - AI 抠像 / Chatterbox TTS 走 ort 的 load-dynamic，只有首次使用这些
    功能时才需要把 onnxruntime.dll 放到本目录；普通剪辑不需要。

[已知取舍]
  - 未做代码签名；Windows SmartScreen 对未签名 exe 可能提示风险。
  - 模板系统目前是设计稿（assets/templates + docs/TEMPLATE-SYSTEM.zh.md），
    运行时不加载。
  - 版本号已按语义化版本递增至 0.2.11；构建时间戳 / 编译器版本见
    BUILD_INFO.txt，运行时依赖说明见 RUNTIME-DEPENDENCIES.md。

[合规]
  LICENSE                AGPL-3.0 全文（上游 Concat）
  THIRD_PARTY_NOTICES.md 第三方组件与许可汇总
  FFmpeg 为 GPL 构建，MinGW 运行库按其各自许可分发。

[溯源]
  BUILD_INFO.txt 记录 product / version / built_at(UTC) / rustc /
  toolchain / target / profile / commit。本工作区无 .git，commit 记为 local。
