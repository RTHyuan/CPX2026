# PathSense 开发交接

记录日期：2026-11-22。本文面向接手开发、复现与验证的人员。项目目标是以中英文语音分阶段引导盲人和低视力人士抵达指定的室内目的地。默认模式已实现现场描述、标识识读和接近可辨认门口的局部引导。多阶段任务另有开发入口和受控画面回放，具体能力及现场验证边界见下文。

## 当前代码基线

- 产品名称在中英文界面中均为 PathSense。
- 原交接所核对的功能基线：`7c6a582`，提交标题 `Checkpoint bilingual visual navigation, local mapping and simulator video demo`。
- Xcode 工程版本：`MARKETING_VERSION = 1.0`，`CURRENT_PROJECT_VERSION = 19`；App 最低 iOS 27.0，Swift 设置为 5.0。
- Swift Package：`PathSenseCore`，用于独立运行核心逻辑测试；Package 平台声明与 App 最低系统版本不是同一个配置。
- 当前 HEAD 包含模拟器视频回放与本机中转的后续改动；此前版本 19 的真机安装、地图与测试记录不自动证明这些后续改动均已验证。
- 项目所有者已于 2026-11-22 确认：上传 `.gitignore` 忽略项之外的全部项目内容，包含原始现场素材、扫描楼层图、实测数据和演示媒体；保留现有提交历史。指定目标为 `https://github.com/RTHyuan/-.git`，发布分支为 `main`。发布结果以远程 `main` 的实际提交为准。

## 目录如何阅读

```text
CPX26/
├── App/                       iOS 界面、相机、网络、语音、设备诊断
│   └── Resources/             中英提示词、本地化、图标、演示素材
├── Core/                      与 UI 分离的识图协议、几何、近场、许可、建图逻辑
├── Tests/                     Swift Package 测试及小型拓扑样例
├── UITests/                   Xcode UI 与相机回放测试
├── PathSense.xcodeproj/        App 工程与共享 scheme
├── Scripts/                   验证、授权、回放、打包、Mac 地图工具
├── Proxy/                     可选 Mac 云端中转及其测试
├── MappingData/               Mac 查看页、扫描楼层图、短时真实采集与说明
├── docs/                      使用、交付、现场验证说明与展示媒体
│   └── archive/2026-11/       早期展示与提交资料归档
├── Training/                  历史训练资料；当前主流程不依赖自训练分类器推理
├── Submission/private/        本地排除的原始工作资料
├── 照片/                      原始现场照片、扫描图、视频
├── output/                    ZIP、录屏、海报等生成交付物
├── .build-local/              多次 Xcode 构建、模拟器、回放、测试和本机证据
├── .build/                    Swift Package 构建缓存
├── .git/                      本地提交历史、索引与 Git 对象
└── .gitignore                 本地缓存、凭据与部分交付物的忽略规则
```

这是职责目录树，不是本次磁盘容量统计；精确体积及隐藏项见[目录审计与上传范围](directory-inventory-20261122.md)。以 `.` 开头的目录通常在 Finder 默认视图中隐藏，也会占用磁盘。大体积构建产物、原始视频和多份输出不属于运行源码本身。当前 `.gitignore` 已忽略 `.build/`、`.build-local/`、`DerivedData/`、`xcuserdata/`、`.env*`、证书与描述文件、`Proxy/local_settings.py` 等；“被忽略”不等于不存在，也不等于文件可公开。

`MappingData/` 已包含在 Git 仓库中。Mac 查看器使用其中的页面、楼层扫描图和一段真机短采集，可按该目录的使用说明载入数据。

## 默认流程与代码入口

默认入口是 `App/PathSenseApp.swift` → `DoorDemoView` → `DoorDemoSession`。启动参数 `--full-navigation` 进入多阶段标识路线开发界面，复现用的画面与预期状态转换见[开发模式说明](wayfinding.md)。

| 文件 | 接手时应关注的职责 |
| --- | --- |
| `App/DoorDemoSession.swift` | 目的地与语言、模型请求、结果时效、单步准备与播报、暂停恢复、地图导出。 |
| `App/DoorDemoView.swift` | 当前首页、识图与指令显示、语言切换、局部地图、JSON 分享。 |
| `App/Camera.swift` | 同一个 ARKit 会话产生图像、位姿、近场和关键帧；Pro 深度点采样；DEBUG 模拟器像素／视频回放。 |
| `App/CloudClient.swift` | 模型请求结构、提示词装载、网络、设备凭据、生产解析；DEBUG 模拟器回环中转。 |
| `Core/DemoGuide.swift` | 六字段 JSON、帧匹配、中英长度与单步动作约束。 |
| `Core/LocalRoute.swift`、`PassageEvidence.swift`、`StepExecution.swift` | 目标方向、身体／脚前证据、一步许可、起播和运动生命周期。 |
| `App/NearVision.swift` | 近场深度／图像证据，深度设备不能因缺少当前深度而默认放行。 |
| `App/Feedback.swift` | 实时语音、模型单步句临时合成与实际起播回调。 |
| `Core/SpatialGeometry.swift` | ARKit 坐标、相机投影、地标方向与三角测量。 |
| `Core/LocalMapping.swift` | 有界会话轨迹、地标、近场和点云记录；不签发行走许可。 |
| `App/Scanner.swift`、`LiveNavigation.swift` | 保留的完整导航控制器、历史线索与旧流程诊断。 |

### 一次识图怎样成为一句指令

1. 相机选择当前完整 JPEG，并附 `session/world/frame`、位姿、图像尺寸。请求包含目的地、最近提示、语言和 `walking_ready`。
2. `CloudClient.guideDemo` 将对应语言提示词、上下文和照片发送给代码中配置的 `deepseek-flash` 接口。这里记录的是当前代码设置，并非对供应商未来可用性的保证。
3. 生产解析器要求帧标识与请求一致，验证文本、动作及实物框。失败、超时或过期结果不进入执行。
4. `scene_zh` 和 `speech_zh` 的内容直接用于显示与语音，英文模式保留兼容字段名但字段内容必须为英文。权限、朝向、近场和停步提示来自本机。
5. `forward` 只是模型的一次短单步提议。本机仍检查当前脚前地面、落脚区域、身体空间、朝向、时效及许可状态；模型已识别不等于现在可迈步。
6. 单步句先实时合成临时音频，在提交与实际起播时再次核对许可。一份模型回包最多消耗一次单步；完成并站稳后取新图再判断。
7. 障碍、视角／位置偏离、追踪重建、暂停、后台或超时会使旧动作失效。补看脚前地面的同向俯仰变化不应单独抹掉仍有效的门方向。

### 模型返回内容和“判断依据”的边界

默认演示严格返回六个键：

```text
frame_id, scene_zh, speech_zh, action, target_kind, target_box
```

其中 `scene_zh` 是可见事实描述，`target_box` 是当前图片中的实物定位框，`action` 是意图。协议**没有独立 `reason`、`plan` 或模型内部推理字段**。不可将这些字段解释成完整推理日志。

`StepExecution` 记录 `offered`、`submitted`、`speechStarted`、`speechEnded`、撤销和运动状态等事件。默认演示的 `recentReplies` 是有界内存摘要，局部地图 JSON 也不是完整的逐帧模型审计日志。若下一阶段要复盘每次“为什么仍停在观察／为什么允许前进”，应补齐可导出的对齐记录：请求帧标识、模型结构化结果、当前位姿、近场证据、拒绝原因、许可与实际起播事件；避免把图片、凭据或个人信息无选择地持久化。

## 实际提示词

- 中文：`App/Resources/deepseek-demo-v1.txt`。
- 英文：`App/Resources/deepseek-demo-en-v1.txt`。
- 保留完整导航的规划提示词：`App/Resources/deepseek-planner-v2.txt`，不要将其与默认演示协议混用。

两份演示提示词都明确模型在引导盲人／低视力用户：只说简短可见事实和一个动作；默认到最近可辨认的门口；读路牌时关联同一设施的箭头，不借用邻行方向；`look` 给出具体观察方向，避免循环泛称“环顾四周”；只允许 `look/turn_left/turn_right/forward/stop`。

中文场景上限 32 字、动作上限 24 字；英文上限分别为 120 与 90 字符。前进必须明确“一步／一小步”或 `one step / one small step`，给出门或实际过道目标框；不得把路牌当入口，不得要求连续行走、上下楼或保证安全。模型不能自行宣布到达，最终由本机和用户核实。

修改提示词时同步检查生产解析器和 `DemoGuideTests`。提示词放宽而解析器不变会造成回包被拒绝；只放宽解析器也不能代替现场验证。

## 建图数据与 Mac 查看

当前路线是 **ARKit VIO 轨迹 + LiDAR 深度点局部累积**，没有独立 LIO 后端。无深度设备可记录 `visual_features` 稀疏视觉点，不能标作 LiDAR 扫描。

- 坐标单位为米，沿用各 ARKit 会话坐标系。世界／会话改变会清空当前累积，不能直接拼接不同坐标段。
- 深度点在支持的 Pro 上约每 0.5 秒采样，取中高置信度、0.2–5 米深度；App 以 8 厘米体素去重，最多 24,000 点。
- 轨迹按位移采样并限制数量；地标仅在已有真实三角测量点时绘制坐标，只有 `bearing` 的方向观测不能补成假点。
- 近场扇区是有时效的方向示意；暂停、停止或失效会清除，不表示永久可通行区域。
- 手机暂停／结束或手动分享产生 `Documents/LocalMaps/PathSense-local-map-<session>-<world>.json`；运行中约每 3 秒原子写出 `PathSense-live-map.json`。
- `MappingData/floorplans/` 是用户提供的 LEVEL G／1／2 真实扫描图。原图、尺寸和哈希见 manifest；没有已校准米制比例或 AR 变换，原牌红星不是手机实时位置。
- `MappingData/floor-reference-example.json` 仅为原有拓扑测试样例，不是这栋楼的实测图。
- `MappingData/captures/pro-local-map.json` 为一次短时真实 Pro 采集，报告明确相机中断；不能作为长距离建图成果。

Mac 使用 Python 标准库，无第三方前端 CDN。在项目根目录运行：

```sh
python3 Scripts/map-viewer.py
```

另一个终端运行：

```sh
python3 Scripts/watch-map-usb.py --device <已配对的设备标识>
```

打开 `http://127.0.0.1:8765/`。手机解锁、信任 Mac、导航保持前台时，USB 脚本读取当前 JSON 后交给本机查看器。也可离线打开 `MappingData/viewer.html` 导入 JSON。完整用法见 [Mac 查看器](../MappingData/Mac查看器.md)；局域网 HTTP 接收不是 App 已实现的自动直播路径。

## 开发环境、构建和配置

当前工程使用 Xcode 27.2 / iOS 27 SDK 路线；实际接手电脑应检查 `xcodebuild -version` 与 `xcrun simctl list devices available`。选择自己的开发团队与设备，不能沿用交接电脑的签名缓存、私钥或绝对路径。

打开 `PathSense.xcodeproj`，使用共享 `PathSense` scheme。真实相机／深度能力需要支持的真机；Core 单元测试可在 Mac 上运行。

```sh
swift test --scratch-path .build-local/handoff-core
python3 -m unittest discover -s Proxy
xcodebuild -project PathSense.xcodeproj -scheme PathSense \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath .build-local/handoff-simulator \
  -parallel-testing-enabled NO test
```

这些是复现命令，**编写本文没有重新执行这些测试**。部分视觉／现场回放需要单独提供素材，见 `Scripts/prepare-field-replay.py`、`Scripts/replay-field.sh` 与相应验证文档；缺少素材的跳过项不可写成已通过。

云端凭据通过本机环境配置或设备授权流程提供。`Scripts/enroll-device-cloud.py --device <设备标识>` 将手机可解的授权送入设备，App 导入后保存在设备钥匙串。交接文档不包含任何实际密钥，也不要求把 `.env`、`Proxy/local_settings.py`、签名证书、描述文件、授权密文或钥匙串数据上传仓库。

保留的 Mac 中转用 `Scripts/start-navigation-proxy.sh`；DEBUG 模拟器中转用 `Scripts/simulator-demo-relay.py`。两者与真机直连的凭据、网络和验证边界应分别理解。

## 模拟器视频演示的限制

当前代码支持 DEBUG 模拟器通过 `PATHSENSE_TEST_VIDEO` 读取本地 RGB 视频，支持 `PATHSENSE_TEST_VIDEO_LOOP`，并可通过 `PATHSENSE_SIMULATOR_DEMO_RELAY` 使用本机回环中转。该模式使用合成静止位姿，明确没有实测姿态、深度或行走许可。它可展示识图文本与语音过程，**不能用录屏画面证明真实 VIO、LiDAR、身体通道或前进执行已经通过**。不要将这些 DEBUG 开关误配置到真机验收中。

## 已有验证记录与不能推导的结论

以下来自此前版本 19 的交付记录和现存文件，不是本次交接编辑新跑出的结果。完整内容见 [版本 19 交付说明](delivery-19.md)。

| 证据 | 已记录的结果 | 主要边界 |
| --- | --- | --- |
| Core 测试 | 181 项，跳过 1，失败 0 | 不证明现场识别和行走精度；跳过不等于通过。 |
| 控制器受控回放 | 32/32 | 相机、云端与音频回调存在受控替身，不是端到端现场验收。 |
| UI | 3 个不同测试最终通过 | 中文首轮 helper 连接失败后单独重跑成功；未验证真实语音听感。 |
| 设备构建安装 | Pro 上记录 build 19 安装和启动成功 | 后续源代码改动不能仅靠相同版本号继承验证。 |
| 真实 Pro 短采集 | 100 正常帧、3 轨迹采样、212 LiDAR 点、1 地标记录 | 8 秒窗口中相机中断，只有方向的地标不等于定位点。 |
| Mac | 上述真实快照接收并显示 | 不等于持续 USB 流稳定性验证。 |

对应原始开发证据主要在被忽略的 `.build-local/indoor-navigation-map-20261122/`；按用户已确认的范围，这个被忽略目录不会上传。已在非忽略目录保存的摘要、地图采集副本和报告属于本次发布范围，不能将其与完整 `.build-local/` 证据库混为一谈。

未验证：盲人用户完整实地流程、持续 USB 更新稳定性、长距离漂移、复杂动态障碍、全程避障可靠性、跨楼层和任意目的地的完整闭环。本项目当前不能作出安全通行保证。

未实现：独立 LIO 状态估计／优化、回环与全局优化、跨会话地图拼接、持久重定位、扫描图自动解析拓扑／尺度／朝向及 AR 配准、全楼任意起终点规划并持续纠偏和核实到达。

## 接手后的优先顺序

1. 固定源码提交与发布清单，重新构建；分开记录源码版本、App build、提示词版本和测试数据来源。不要仅以“都是版本 19”判断代码一致。
2. 在有人陪同的受控区域做无中断持续采集，核验 VIO／LiDAR 来源、USB 更新、暂停／追踪重建和旧坐标清理。
3. 补齐“当前照片—模型结果—本机证据—许可—起播—实际移动—下一帧”的可导出对齐记录，优先定位停在观察的真实原因。
4. 验证中英文实际云端请求与语音起播、打断和恢复，分别记录网络延迟及失败路径。
5. 对真实扫描图标注控制点、米制尺度和通道拓扑，先测人工配准误差，再决定自动配准、跨会话和更大范围路线。

## 已确认的 GitHub 发布范围

项目所有者于 2026-11-22 在阅读目录审计后，选择上传 `.gitignore` 忽略项之外的全部内容，即此前 A／B／C 范围以及原始现场照片、视频与其他非忽略文件。目标远程为 `https://github.com/RTHyuan/-.git`，使用 `main`，按用户给出的 Git 推送流程保留现有提交历史。发布范围按此记录执行；具体版本以远程 `main` 提交为准。

已被 `.gitignore` 忽略的构建缓存、DerivedData、`.env*`、`Proxy/local_settings.py`、证书／描述文件、部分 ZIP 和私有提交资料等不纳入。`output/`、`照片/` 等目录并没有整体被忽略，其中未被忽略的文件也属于用户本次选择。Git 忽略规则不会自动抹掉已经提交的历史内容；保留现有历史意味着相关历史对象也会随 Git 推送保留。`.git/` 是本地仓库数据库，不作为普通源码目录另行添加。

`Scripts/package-source.py` 是已有 ZIP 白名单工具，并非整个当前工作区的镜像。当前打包清单包含交接文档、目录说明和模拟器中转脚本。旧版 ZIP 保留生成时的文件。
