# PathSense 1.0（14）源码

用 Xcode 27.2 打开本目录的 `PathSense.xcodeproj`，选择 **PathSense** scheme。真机目标是 iPhone 17 Pro，App 最低系统为 iOS 27.0。安装到自己的设备前，在 Signing & Capabilities 中选择自己的开发团队。

说「带我去厕所」后，规划层保留最终目的地，按现场证据选择过道、门或标识。执行层在本机确认脚前、落脚点和身体通道，检查通过才提示「向前迈一步」。这一步完成、过期或遇到障碍后，下一次播报需要新的观察。使用步骤见[使用手册](docs/wayfinding.md)。

| 目录 | 内容 |
|---|---|
| `App/` | SwiftUI 界面、相机、视觉、语音、触觉和 DeepSeek 客户端。资源含按用户原图适配的白底图标、一步提示音、公开实拍门照和共享规划模板。 |
| `Core/` | 规划协议、地标与位姿、通行证据、一步许可及播报状态。 |
| `Proxy/` | 可选的 Mac 代理与协议测试。手机直连使用 `App/` 内的客户端。 |
| `Tests/`、`UITests/`、`Scripts/` | 核心及界面用例、回放脚本、原始帧索引和校验值。 |
| `Verification/` | 已完成的安装、自动化测试、模拟器逐步回放及真机自检记录。 |
| `Training/` | 历史训练源码。正式 App 使用系统视觉与传感器。 |

**运行测试和构建**。在此目录执行以下命令。模拟器构建无需签名。

```sh
swift test
python3 -m unittest discover -s Proxy -p 'test_*.py'
xcodebuild -project PathSense.xcodeproj -scheme PathSense -configuration Debug   -destination 'generic/platform=iOS Simulator' -derivedDataPath .build-local/simulator CODE_SIGNING_ALLOWED=NO build
```

若需重跑用到现场像素的用例，将原始 `照片/` 放回工程根目录，然后按[回放说明](docs/navigation-step-pro.md)提取并校验素材。包内带公开 CC0 门照、测试标牌和逐帧验收摘要。私有原始现场照片和录像单独保管，缺少对应素材时，相关核心像素用例会跳过。

**本版验收**。iPhone 17 Pro 用公开门照两次直连 DeepSeek，均收到 HTTP 200 和对应帧的模型回复，分别耗时 2.150 秒和 2.676 秒。两次均使用非蜂窝网络，未使用系统代理，Mac 演示代理在各次请求全程暂停。蜂窝网络与拔线使用尚未实测。 核心、代理、构建及设备检查分别记录在[验收记录](Verification/验收说明.md)。

**公开门照自检**。打开「使用说明 → 云端视觉 → 用公开门照测试连接」。测试使用随包 CC0 门照和测试位姿。导航中发送现场关键帧需要另行同意。设备授权工具的用法可运行 `python3 Scripts/enroll-device-cloud.py --help` 查看。[云端自检结果](Verification/云端自检.json)

[技术路线](PathSense-技术路线-SLAM与VLM.md) · [素材来源](ASSET-CREDITS.md) · [源码许可证](LICENSE)
