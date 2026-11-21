# PathSense · 室内寻路

为低视力访客设计的 iPhone 辅助导航。输入房号、科室、店名或设施，点击「开始导航」，后置相机持续观察门、楼层目录和路口标识。手机记住已经读到的线索，引导使用者站定核对下一块标牌。[使用手册](docs/wayfinding.md) · [离线演示](docs/index.html)

*PathSense helps people with low vision follow indoor signs to a room, department or shop. A continuous rear-camera feed supplies the evidence. The traveler checks the passage and confirms arrival.*

## 在 iPhone 上运行

用 Xcode 打开 `PathSense.xcodeproj`，选择 `PathSense` scheme 和自己的 iPhone，在 Signing & Capabilities 选开发团队。项目的最低部署版本为 iOS 27.0。本项目使用 Xcode 27.2。首次运行允许相机，即可输入任意目的地开始导航。听写可使用系统键盘。模拟器的自动化测试通过测试包提供的像素运行相同的识别流程。[Apple 设备与签名说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

## 现场流程

1. 在房间、大厅或入口站定，缓慢环顾。发现疑似门时，手机提示门在镜头中的位置，通过前由使用者核对通道。
2. 扫过门牌、目录或标识，手机读取当前地点或目标所在行。房号保留前导零。目录的楼层写入目标位置，独立楼层牌或「您在此」用于确认当前位置。
3. 在换层点、梯厅和转角依次对准现场标牌。多次一致的观察会更新提示，同一块牌保持在镜头里时可按「重听」。
4. 核对独立门牌或店招后确认到达。途中可暂停、继续、换目标或重新定位。进入后台会停止采集。

## 界面和隐私

首页、导航页和使用说明采用 SwiftUI 系统导航栏、SF Symbols、动态字号和自适应深浅色。导航栏的返回箭头和问号各有至少 44 点的点击区域。分组、提示卡和按钮使用 G² 连续大圆角。点「开始导航」会自动用普通话读出目的地和第一步。开始、方向更新和确认到达分别提供触觉反馈。同一块牌持续在镜头里时，可以点「重听」再听一次。导航画面在本机处理。最近搜索只保存房号和常用设施，自由输入的科室与店名仅用于当次寻路。

## 从镜头到提示

| 实现 | 作用 |
|---|---|
| `App/Camera.swift` | 用 AVFoundation 采集后置镜头，丢弃迟到帧，每隔至少 0.5 秒取样。处理方向、权限、系统中断和恢复。 |
| `App/SignVision.swift`、`App/RouteVision.swift` | 本机 Vision OCR 提供文字与位置，多尺度比对疑难文字。图形箭头与相邻文字分别核对。场景分类和门框、地面几何线索给出疑似门的位置。 |
| `Core/Signs.swift`、`Training/sign-layout.csv` | 对照完整房号、范围和限制词，用 Core ML 版式分类器辅助区分列表与单牌。 |
| `Core/WayfindingSigns.swift`、`Core/Wayfinding.swift` | 按行、列和楼层标题匹配目标。记住已知楼层，处理同名条目、错层、沿途提示与到达确认。 |
| `App/Scanner.swift` | 对比连续两次的完整线索，保持当前提示，隔离切后台、暂停、换目标前的帧。 |

## 验证和复现

核心测试覆盖自由输入、房号边界、同名条目、楼层标题、错层和重复帧。视觉检查用相机格式像素回放教学楼、医院和商场的标识序列，并检查陌生店名、图形箭头和无字门。界面测试从首页「开始导航」进入，自动更换镜头内容，覆盖恢复、换目标、权限提示和辅助字号。相机回放图片只打入 UI 测试包。实地全程、实际触觉和 VoiceOver 听感待现场验证。[验证范围与展桌操作](docs/wayfinding.md#展桌试用)

```bash
swift test --scratch-path .build-local/core
Scripts/verify-vision.sh
xcodebuild -project PathSense.xcodeproj -scheme PathSense \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath .build-local/simulator -parallel-testing-enabled NO test
xcodebuild -project PathSense.xcodeproj -scheme PathSense -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build-local/device CODE_SIGNING_ALLOWED=NO build
```

用 `xcrun simctl list devices available` 查询模拟器编号后替换 `SIMULATOR_UDID`。`python3 Scripts/record-exhibit.py SIMULATOR_UDID` 可录制连续寻路界面。`python3 Scripts/make-route-signs.py --external .build-local/route-external` 生成额外测试牌，设 `PATHSENSE_EXTERNAL_SIGNS=.build-local/route-external` 后运行视觉检查。`Scripts/verify-vision.sh --printable-signs DIRECTORY` 可检查已按页渲染的展桌测试牌。

## 演示和许可

直接打开 `docs/index.html` 可离线观看，或用 `python3 -m http.server 8000 --bind 127.0.0.1 --directory docs` 在本机提供展页。展桌可在另一块屏幕放大标牌，供 iPhone 后置相机扫描。标牌册的第 7–13 页可从门一路练到 402，第 14–19 页和第 20–25 页分别对应科室与商铺。[A3 海报](docs/media/pathsense-poster.pdf) · [打印标牌](docs/media/field-signs.pdf)

使用 Codex 协助实现与测试。工程采用 SwiftUI、AVFoundation、Vision、Core ML、Create ML、UIKit 和 XCTest。测试标牌及图标由项目绘制，印刷物采用 ReportLab 排版，门的实拍照片来自 Samuel Zeller 的 CC0 作品。源码采用 Apache License 2.0。[素材说明](ASSET-CREDITS.md) · [许可证](LICENSE)
