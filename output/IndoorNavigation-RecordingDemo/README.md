# PathSense · 室内寻路

当前版本为 **1.0（19）**，默认首页为 **室内寻路 / Indoor Navigation**，采用目的地输入、常用设施、最近目标和语音开关的界面。首页底部可切换中文与 English，DS 直接返回所选语言的简短描述和动作，手机实时合成对应语音；本机检查通过后可主动提示向前一小步，到门口结束。[演示操作与语音说明](docs/door-demo.md)。右上角为使用说明；原完整导航可用启动参数 `--full-navigation` 打开。

以下完整导航资料保留供开发参考；默认演示的流程、语言和验证范围以[演示说明](docs/door-demo.md)为准。

版本 19 新增会话局部地图、ARKit VIO 轨迹、Pro LiDAR 深度点云导出与 Mac 查看器，界面移除模型品牌字样。用户提供的 LEVEL G／1／2 真实扫描图已收入 `MappingData/floorplans/`。Mac 运行 `python3 Scripts/map-viewer.py`，另一个终端运行 `python3 Scripts/watch-map-usb.py` 可通过 USB 跟随手机导航数据。具体步骤及尚未完成的配准、LIO 与验证范围见 [Mac 查看器](MappingData/Mac查看器.md) 与 [本次交付说明](docs/delivery-19.md)。

为低视力访客设计的 iPhone 辅助导航。说出最终目的地，例如「带我去厕所」。手机会寻找可复核的中间目标，只有在本机重新看清脚前地面、落脚区域和身体通道后，才会说「向前迈一步」。[使用手册](docs/wayfinding.md) · [iPhone 17 Pro 开发与验证](docs/navigation-step-pro.md)

*PathSense helps people with low vision follow indoor signs to a room, department or shop. A continuous rear-camera feed supplies the evidence. The traveler checks the passage and confirms arrival.*

## 在 iPhone 上运行

用 Xcode 打开 `PathSense.xcodeproj`，选择 `PathSense` scheme 和自己的 iPhone，在 Signing & Capabilities 选开发团队。本次部署目标为 iPhone 17 Pro，最低 iOS 27.0。中文听写使用 `installAudioTap`。本项目使用 Xcode 27.2。首次使用相机、麦克风和中文听写时按提示授权。点「说出目的地」启动 Apple 本机中文识别。权限或语言资源不可用时可改用文字。模拟器的自动化测试通过测试包提供的像素运行相同的识别流程。[Apple 设备与签名说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

## 现场流程

1. 在房间里去公共设施，先寻找通往公共区域的出口。座椅挡在门前时，可先接近侧过道。在公共走廊直接寻找标识。单个房号不能确定人在门内还是门外，位置不明确时可在界面确认。
2. 按提示原地转向。对准后会轻震，让手机朝身体前方，按提示观察身体通道和脚前地面。听到「向前迈一步」只走一步，然后站稳。保持朝向时，下一步自动重新检查。转身、移动偏离、障碍或追踪中断都会使旧许可失效。
3. 到教室门口继续核对是否已通过。进入走廊后仍寻找原来的厕所、房号或其他目的地。方向箭头用于找下一处现场线索，远处看到终点门牌还需要接近并核对。遇到台阶，留在原地查看两侧的平坦通道。没有可确认的平坦路线时请陪同人员协助。
4. 途中可暂停、继续、换目标或重新定位。重听会重新核对动作。暂停后可在使用说明中分享本次许可、运动和实际播报记录。进入后台会停止采集。

## 界面和隐私

首页、导航页和使用说明采用 SwiftUI 系统导航栏、SF Symbols、动态字号和自适应深浅色。导航栏的返回箭头和问号各有至少 44 点的点击区域。分组、提示卡和按钮使用 G² 连续大圆角。点「开始导航」会自动用普通话读出目的地和第一步。开始、方向更新和确认到达分别提供触觉反馈。同一块牌持续在镜头里时，可以点「重听」再听一次。默认在本机处理。用户在帮助页启用云端并同意后，当前完整关键帧、最多两张相关历史关键帧、用户原话与最终目的地、相应位姿和附近地标摘要会发送给 DeepSeek。已配置直连的 iPhone 通过自己的网络发送，手动配对的设备则经演示 Mac 转发。实时近场图仅供手机使用。暂停、进入后台或结束会停止新的采集和上传。最近搜索只保存房号和常用设施，自由输入的科室与店名仅用于当次寻路。

## 从镜头到提示

| 实现 | 作用 |
|---|---|
| `App/Camera.swift` | 一个 ARKit 世界追踪会话提供预览、Vision 和关键帧。每帧更新方向，约每 0.5 秒保存位姿摘要。 |
| `App/SignVision.swift`、`App/RouteVision.swift` | 本机 Vision OCR 提供文字与位置，多尺度比对疑难文字。图形箭头与相邻文字分别核对。场景分类和门框、地面几何线索给出疑似门的位置。 |
| `Core/Signs.swift` | 用完整房号、范围、分隔符和目录关键词区分列表与单牌。系统 Vision 提供 OCR。 |
| `Core/WayfindingSigns.swift`、`Core/Wayfinding.swift` | 按行、列和楼层标题匹配目标。记住已知楼层，处理同名条目、错层、沿途提示与到达确认。 |
| `Core/LocalRoute.swift`、`Core/PassageEvidence.swift`、`Core/StepExecution.swift` | 用目标框和内参求方向，原地转动后重算。Pro 优先检查深度和置信度，按观察帧、朝向和位置签发一步许可。|
| `App/LiveNavigation.swift`、`Proxy/server.py` | 云端提供语义候选，手机按最新位姿重算方向。停步抢占信号来自本机。|
| `App/Scanner.swift` | 对比连续两次的完整线索，保持当前提示，隔离切后台、暂停、换目标前的帧。 |

## 云端连接

Release 1.0（14）已在 iPhone 17 Pro 上通过 DeepSeek 直连自检。暂停 Mac 上的演示代理后，两次手机请求各收到 HTTP 200，公开门照和回复帧号都通过校验，耗时 2.150 秒和 2.676 秒。两次使用非蜂窝网络，未单独做蜂窝或拔线测试。打开「使用说明 → 云端视觉」，点「用公开门照测试连接」可复查。点「启用云端视觉」并确认后，导航才会发送现场画面。

首次为另一台已配对的 iPhone Pro 或 Air 配置直连时，安装本版、解锁并启动一次。用 `python3 Scripts/enroll-device-cloud.py --device <设备标识>` 在开发 Mac 上进行一次性授权，再在手机上点「用公开门照测试连接」。工具优先使用私有环境配置 `PATHSENSE_DEVICE_DEEPSEEK_API_KEY`，缺省时读取现有代理的配置。在应用之外，仅此手机可解的密文会送入设备。App 在本机解密后把凭据写入仅此设备解锁时可用的钥匙串。注册完成后，日常使用云端只需手机联网。

未配置直连的设备仍可手动配对演示 Mac。

在工程根目录运行 `./Scripts/start-navigation-proxy.sh`。本机演示代理优先读取环境变量 `DEEPSEEK_API_KEY`，也可直接读取演示 Mac 上私有的明文源码配置 `Proxy/local_settings.py`（变量名相同）。该文件只留在本机。Mac 和 iPhone 加入同一可信 Wi-Fi，在 iPhone 的「使用说明 → 云端视觉」填入终端显示的完整配对地址，点「启用云端视觉」并阅读授权说明。使用 `.local` 主机名和本轮地址尾部的随机串。若系统询问本地网络权限，允许后开始新一轮扫描。服务端把图文请求转给 `deepseek-flash`。按 `Ctrl-C` 可结束本轮配对。

自训练的 `SignContext`、训练样本、训练脚本和历史推理代码保存在仓库。App 和常规测试仅运行系统 Vision 和规则解析。可用 `python3 Scripts/check-app-bundle.py <PathSense.app 路径>` 检查实际安装包。

现场实拍回放可运行 `Scripts/replay-field.sh SIMULATOR_UDID`。现场素材来源与注入条件见[Pro 验证记录](docs/navigation-step-pro.md)，以往结果见[现场反馈](docs/field-feedback.md)

## 验证和复现

核心测试覆盖自由输入、房号边界、同名条目、楼层标题、错层和重复帧。视觉检查用相机格式像素回放教学楼、医院和商场的标识序列，并检查陌生店名、图形箭头和无字门。界面测试从首页「开始导航」进入，自动更换镜头内容，覆盖恢复、换目标、权限提示和辅助字号。相机回放图片只打入 UI 测试包。实地全程、实际触觉和 VoiceOver 听感待现场验证。[验证范围与展桌操作](docs/wayfinding.md#展桌试用)

```bash
python3 Scripts/prepare-field-replay.py
PATHSENSE_REAL_FRAMES_DIR="$PWD/.build-local/field-feedback/real-frames" swift test --scratch-path .build-local/core
python3 -m unittest discover -s Proxy
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
