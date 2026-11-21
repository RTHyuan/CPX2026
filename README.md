# PathSense · 室内标牌识读

一个低视力学生已经到达教学楼三层，课表上的房号是 305。PathSense 让他站定后用普通 iPhone 扫描标牌，听清眼前读到的号码，以及这段文字和 305 有什么关系。使用者可以随时换目标、暂停、重听，或展开识别原文自行核对。

*PathSense helps people with low vision check indoor signs against a room or facility they are looking for. It reads visible text on the iPhone and distinguishes a room plate, a number range and a directory entry.*

## 看演示

双击 `docs/index.html`，或从项目根目录运行 `python3 -m http.server 8000 --bind 127.0.0.1 --directory docs`，用浏览器打开 `http://127.0.0.1:8000/`。演示包含 17.95 秒的 iOS 模拟器照片模式实录、中英文字幕、逐段文字和五张结果截图。下方另有一张使用系统相册导入 `418` 门牌后的实际界面。网页及媒体均可离线查看。[演示入口](docs/index.html) · [MP4](docs/media/pathsense-demo.mp4)

## 运行 iPhone App

1. 用装有 iOS SDK 的 Xcode 打开 `PathSense.xcodeproj`。当前 App 的最低部署版本为 iOS 27.0。开发使用 Xcode 27.2，界面测试在 iOS 27.2 模拟器上运行。App 使用随系统提供的框架，工程已包含编译所需的模型和练习标牌。
2. 选择 `PathSense` scheme 和一个 iPhone 模拟器，按 **⌘R**。首页点「用照片试一试」，留空会自动采用 305。依次点「303」「301–310」「3050」「305」「楼层目录」，再点「换目标」选择「电梯」。也可以从照片选择器导入自己的标牌。
3. 真机运行时，在 **Xcode → Settings → Apple Accounts** 登录自己的 Apple 账户。在 **Targets → PathSense → Signing & Capabilities** 选择自己的 Team 并开启自动签名。如果该 Bundle Identifier 已被占用，换为团队唯一的 ID。连接并解锁 iPhone，按系统提示配对、启用 Developer Mode，选择该 iPhone 后按 **⌘R**。运行 UI 测试到真机时也为测试 target 选 Team。[Apple 的设备与签名说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
4. 首页可键入房号，或点系统键盘的听写按钮说「我要找三零五教室」「帮我找电梯」。如果房号有前导零，逐位说「零三零五」会得到 `0305`。点「开始扫描」，首次使用同意相机权限。站定后将后置镜头对准附近的牌面。可切换到「拍一次」，由使用者按下「拍照识字」。相机权限被拒或设备没有后摄时仍可进照片模式。切后台会暂停，回来后点「继续」。

展桌可以使用 [六张单面 A4 测试牌](docs/media/field-signs.pdf)。先找 305，依次扫独立 305、3050、区间和目录。改找 0305 或 B217，再扫第五、六页。

## 识别和反馈怎样工作

| 当目标是 305 | 用户得到的线索 |
|---|---|
| `ROOM 303` 或 `3050` | 读出实际号码，保留目标 305。 |
| `301–310` 或 `305–310` | 解释这个范围包含目标，保留区间的两个端点。 |
| `DIRECTORY` 下的 `303 / 305 / 307` | 只说明目录提及 305，提示核对独立标识。 |
| 独立 `ROOM 305` | 读出号码，请使用者确认门牌。连续扫描需跨帧确认。 |
| 光线不足、低置信度或内容不完整 | 等待更清楚的图像或提示调整手机角度。 |

目标还可选电梯、楼梯、出口、洗手间。设施判断识别中英文别名。对「电梯维修中」「NO EXIT」等同画面限制词，系统提示核对原文。收录的限制词有限。使用者继续依靠既有的出行辅助和现场指引判断路线、障碍及疏散方向。

| 文件或目录 | 职责 |
|---|---|
| `App/Camera.swift` | AVFoundation 采集后置镜头，丢弃迟到帧，连续模式每隔至少 0.5 秒取一帧，处理方向、权限和中断。 |
| `App/SignVision.swift` | Vision 读取文本、置信度和位置，疑难帧额外进行一次英文识别。导入照片先按 EXIF 方向生成缩略图。 |
| `Core/Signs.swift` | 规范化全角文本，检查完整房号和区间边界，从号码数量、目录词和分隔符等判断标识类型。 |
| `Training/sign-layout.csv`、`Scripts/train-context.swift` | 用 21 条自行构造的版式样本训练 Create ML 逻辑回归。随附 `SignContext.mlmodel`，由 Core ML 在设备端推理。分类器只能把含混的房号降为目录线索。 |
| `Core/ScanGate.swift` | 在 2.5 秒窗口内，最近三个独立采样至少两个判断相同才发布连续识读结果。镜头停留时保持安静。新标牌跨帧确认后立即替换上一条提示。暂停、切换识读模式和恢复取景共用本轮的成功触觉记录。 |
| `App/Scanner.swift`、`App/Views.swift` | 管理任务、拍照与导入、字号和读屏控件。VoiceOver 启用时发系统公告。其他情况下按语音设置播报。成功时请求一次系统触觉。 |

[iPhone 键盘听写](https://support.apple.com/zh-cn/guide/iphone/iph2c0651d2/ios)将口述转成输入框文字。PathSense 在本机解析这段文字，并将选中的房号显示在扫描页。相机帧、导入照片及 OCR 在设备内处理。这个原型只将最近四个目标及语音开关写入本机偏好。设备取用 iCloud 照片时，照片选择器可能需要先下载用户选定的图片。演示用的练习图片已打包在 App 内。

## 验证记录 · 2026-11-21

| 环境 | 运行及结果 |
|---|---|
| Swift / XCTest | 15 项通过。涵盖口述目标及前导零、全角数字、房号前后缀、区间端点、目录、停用设施、多帧确认、去重、空画面和重新对准同一房号。 |
| macOS / Vision + Core ML | 7 张原创受控图全部得到预期类别，4 组固定版式输入均得到预期模型判断。双语电梯图的中文字被读成「电様」且置信度为 0.3，英文 `ELEVATOR` 被正确识别。这组样例不能估计现场准确率。 |
| macOS / 相机帧输入 | 将同一套练习牌转成后摄采集所用的 1280 × 720 双平面 YUV 像素格式，使用四种方向输入生产识字代码。17 帧的分类和提示时机均符合预期。镜头从 305 移向 3050 时，第二个一致采样将提示换为其他房号。再次对准 305 或扫过空画面后恢复，整段只请求一次成功触觉。序列中的时间由测试指定。 |
| iOS 27.2 模拟器 | 6 项 UI 测试通过，包括练习牌全流程、换目标、重听、暂停、输入校验、无后置相机降级、最大动态字号及指定无障碍审计。相册用例从系统照片选择器两次导入新生成的、带 EXIF 方向的 `ROOM 418`，先找 418，随后找 419，两次反馈均符合预期。输入框用例传入“我要找零三零五教室”，再读独立 305，应用保留目标 0305 并读出两者不同。审计覆盖部分控件可发现性、描述和点击区域。 |
| iPhone Air · iOS 27.2.1 | 16:55 已安装版本 1.0（构建 2），17:02 成功启动，并从这台设备读到 PathSense 进程。走廊识读时延、实际触觉、VoiceOver 播放和飞行模式体验待实测。 |
| macOS / 打印牌面的 PDF 渲染图 | 六页按 120 DPI 渲染，实际 Vision OCR 在八种“牌面与目标”组合中均得到预期类型和房号。第五页分别找 305 与 0305，第六页分别找 B217 与 217。 |
| 源码构建 | 从公开源码包独立构建的 iPhone arm64 Release 已通过无签名编译。 |

受控图片由项目脚本生成。模型的四组输入用于确认推理可运行，验证范围不包含独立采集的标牌数据集。用户研究的背景见 Fusco 与 Coughlan 关于视障出行者获取室内视觉线索的原始研究。本项目仍需记录目标使用者对准标牌和理解提示的过程。[研究摘要](https://pubmed.ncbi.nlm.nih.gov/33163996/)

在 macOS 上从仓库根目录复现，可先用 `xcrun simctl list devices available` 取本机模拟器编号，替换 `SIMULATOR_UDID`。

```bash
swift test --scratch-path .build-local/core
Scripts/verify-vision.sh
xcodebuild -project PathSense.xcodeproj -scheme PathSense \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath .build-local/simulator -parallel-testing-enabled NO test
xcodebuild -project PathSense.xcodeproj -scheme PathSense -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build-local/device \
  CODE_SIGNING_ALLOWED=NO build
```

要复核打印牌，用 `mkdir -p .build-local/print-pages` 建立临时目录，执行 `pdftoppm -r 120 -png docs/media/field-signs.pdf .build-local/print-pages/page`，再运行 `Scripts/verify-vision.sh --printable-signs .build-local/print-pages`。`python3 Scripts/make-field-signs.py` 用 ReportLab 重新生成六页 PDF。

完整运行含系统相册的六项测试，使用有 Pillow 的 Python 执行 `python3 Scripts/verify-photo-import.py SIMULATOR_UDID`。脚本按照所给设备类型与运行时新建临时模拟器，导入 418 测试图，运行测试后清理该临时设备并保存测试结果包。常规 `xcodebuild test` 运行其余五项，在日用模拟器上跳过需要布置相册的用例。

`xcrun swift Scripts/train-context.swift` 从 CSV 再训练并写入工程模型。`python3 Scripts/make-practice.py` 使用 Pillow 和系统字体重绘内置测试牌及 App 图标。`python3 Scripts/record-exhibit.py SIMULATOR_UDID` 在已启动的模拟器录制照片流程，在 `.build-local` 输出原片、测试包和有时间戳的截图。截取展示片段时按当次画面确定起止时刻。

## 工具、素材与许可

- 使用 Codex 辅助整理设计、实现 Swift 代码、编写测试、准备演示和文档。Apple 的 Xcode、Swift/SwiftUI、AVFoundation、Vision、Core ML、Create ML、PhotosUI、UIKit 和 XCTest 提供编译及系统能力，继续适用 Apple 相应条款。
- 练习图、App 图标和版式特征样本由项目生成。模拟器截图取自实际运行。系统提供标识图案及字体。Python 的 Pillow 与 ReportLab 用于制作练习素材和排版，不随 App 分发库或字体文件。
- 海报工作流预留活动指定的 Dify / AMD Creative Factory Image。取得同次生成的 AMD 原图和 Gallery 截图之后，才可生成正式海报并披露本次实际使用。本项目的源代码采用 Apache License 2.0。[许可证全文](LICENSE)
