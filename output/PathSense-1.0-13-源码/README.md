# PathSense 1.0（13）源码

用 Xcode 27.2 打开本目录的 `PathSense.xcodeproj`，选择 **PathSense** scheme。真机目标是 iPhone 17 Pro，App 最低系统为 iOS 27.0。安装到自己的设备前，在 Signing & Capabilities 中选择自己的开发团队。

说「带我去厕所」后，规划层保留最终目的地，按现场证据选择过道、门或标识。执行层在本机确认脚前、落脚点和身体通道，检查通过才提示「向前迈一步」。这一步完成、过期或遇到障碍后，下一次播报需要新的观察。使用步骤见[使用手册](docs/wayfinding.md)。

| 目录 | 内容 |
|---|---|
| `App/` | SwiftUI 界面、相机、视觉、语音、触觉和 DeepSeek 客户端。资源含本版图标、一步提示音、公开实拍门照和共享规划模板。 |
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

**验收结果**。核心测试 147 项、代理及协议测试 16 项通过。模拟器连续两次实际开播，两次分别引用三个不同的现场视频帧。位姿、门框和通行证据由回放注入。较早的整套界面回归有 7 项失败、1 项跳过。iPhone 17 Pro 已安装并启动 1.0（13），已做静置诊断，尚未陪同实走。见[验收记录](Verification/验收说明.md)。

**手机独立云端状态**。Mac 已用公开门照收到 DeepSeek 回复。这台 iPhone 的直连自检返回 `missing_device_enrollment`，尚未取得模型回复。手机需要自己的设备授权才能独立使用云端。手机取得授权后，可在「使用说明 → 云端视觉」中点「用公开门照测试连接」，发送现场画面需另行同意。[云端自检记录](Verification/云端自检.json)

[技术路线](PathSense-技术路线-SLAM与VLM.md) · [素材来源](ASSET-CREDITS.md) · [源码许可证](LICENSE)
