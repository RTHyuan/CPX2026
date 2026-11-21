# PathSense · 室内寻路

为低视力访客设计的 iPhone 辅助导航。点「说出目的地」，说「带我去教室门口」，或输入房号、科室、店名和设施。相机持续扫描，手机根据本次位姿记住门的方向，检查眼前短通道，并在需要时提示停步。[使用手册](docs/wayfinding.md) · [离线演示](docs/index.html)

*PathSense helps people with low vision follow indoor signs to a room, department or shop. A continuous rear-camera feed supplies the evidence. The traveler checks the passage and confirms arrival.*

## 在 iPhone 上运行

用 Xcode 打开 `PathSense.xcodeproj`，选择 `PathSense` scheme 和自己的 iPhone，在 Signing & Capabilities 选开发团队。最低支持 iOS 26.0。中文听写在 iOS 26 使用 `installTap`，在 iOS 27 及以上使用 `installAudioTap`。本项目使用 Xcode 27.2。首次使用相机、麦克风和中文听写时按提示授权。点「说出目的地」启动 Apple 本机中文识别。权限或语言资源不可用时可改用文字。模拟器的自动化测试通过测试包提供的像素运行相同的识别流程。[Apple 设备与签名说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

## 现场流程

1. 找教室门时先站定环顾。远处认出门时会播「找到门了」。听到方向对准的轻震后，让手机朝向身体前方，确认眼前地面。遇到人、障碍或疑似下行台阶时先停。到门边时重新核对同一扇门。
2. 扫过门牌、目录或标识，手机读取当前地点或目标所在行。房号保留前导零。目录的楼层写入目标位置，独立楼层牌或「您在此」用于确认当前位置。
3. 在换层点、梯厅和转角依次对准现场标牌。多次一致的观察会更新提示，同一块牌保持在镜头里时可按「重听」。
4. 核对独立门牌或店招后确认到达。途中可暂停、继续、换目标或重新定位。进入后台会停止采集。

## 界面和隐私

首页、导航页和使用说明采用 SwiftUI 系统导航栏、SF Symbols、动态字号和自适应深浅色。导航栏的返回箭头和问号各有至少 44 点的点击区域。分组、提示卡和按钮使用 G² 连续大圆角。点「开始导航」会自动用普通话读出目的地和第一步。开始、方向更新和确认到达分别提供触觉反馈。同一块牌持续在镜头里时，可以点「重听」再听一次。默认在本机处理。用户在帮助页启用云端并同意后，选中的 JPEG、用户目的地、相应位姿和附近地标摘要会经配对的 Mac 转给 DeepSeek。实时近场图仅供手机使用。暂停、进入后台或结束会停止新的采集和上传。最近搜索只保存房号和常用设施，自由输入的科室与店名仅用于当次寻路。

## 从镜头到提示

| 实现 | 作用 |
|---|---|
| `App/Camera.swift` | 一个 ARKit 世界追踪会话提供预览、Vision 和关键帧。每帧更新方向，约每 0.5 秒保存位姿摘要。 |
| `App/SignVision.swift`、`App/RouteVision.swift` | 本机 Vision OCR 提供文字与位置，多尺度比对疑难文字。图形箭头与相邻文字分别核对。场景分类和门框、地面几何线索给出疑似门的位置。 |
| `Core/Signs.swift` | 用完整房号、范围、分隔符和目录关键词区分列表与单牌。系统 Vision 提供 OCR。 |
| `Core/WayfindingSigns.swift`、`Core/Wayfinding.swift` | 按行、列和楼层标题匹配目标。记住已知楼层，处理同名条目、错层、沿途提示与到达确认。 |
| `Core/LocalRoute.swift`、`Core/PassageEvidence.swift` | 区分目标方位与地面证据，实时扇区和局部占据记录可以否决下一步。Air 使用单目路径。|
| `App/LiveNavigation.swift`、`Proxy/server.py` | 代理提供语义候选，手机按最新位姿重算方向。停步抢占信号来自本机。|
| `App/Scanner.swift` | 对比连续两次的完整线索，保持当前提示，隔离切后台、暂停、换目标前的帧。 |

## 演示 Mac 与 iPhone 配对

在工程根目录运行 `./Scripts/start-navigation-proxy.sh`。本机演示代理优先读取环境变量 `DEEPSEEK_API_KEY`，也可直接读取演示 Mac 上私有的明文源码配置 `Proxy/local_settings.py`（变量名相同）。该文件只留在本机。Mac 和 iPhone 加入同一可信 Wi-Fi，在 iPhone 的「使用说明 → 云端视觉」填入终端显示的完整配对地址，点「启用云端视觉」并阅读授权说明。使用 `.local` 主机名和本轮地址尾部的随机串。若系统询问本地网络权限，允许后开始新一轮扫描。服务端把图文请求转给 `deepseek-flash`。按 `Ctrl-C` 可结束本轮配对。

自训练的 `SignContext`、训练样本、训练脚本和历史推理代码保存在仓库。App 和常规测试仅运行系统 Vision 和规则解析。可用 `python3 Scripts/check-app-bundle.py <PathSense.app 路径>` 检查实际安装包。

**产品待决定**：未来如何为用户提供大模型服务，由产品方另行决定。本轮用演示 Mac 配对。

现场实拍回放可运行 `Scripts/replay-field.sh SIMULATOR_UDID`。恢复私有视频帧和查阅逐段结论见[本轮开发与验证](docs/field-feedback.md) · [Air 验证记录与路线差异](docs/air-field.md)

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

使用 Codex 协助实现与测试。当前导航采用 SwiftUI、ARKit、Vision、Speech、AVFoundation、UIKit 和 XCTest。测试标牌及图标由项目绘制，印刷物采用 ReportLab 排版，门的实拍照片来自 Samuel Zeller 的 CC0 作品。源码采用 Apache License 2.0。[素材说明](ASSET-CREDITS.md) · [许可证](LICENSE)
