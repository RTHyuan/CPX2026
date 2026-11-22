# iPhone 17 Pro 一步导航验证

本轮针对正式工程 `PathSense.xcodeproj`，部署目标为 iPhone 17 Pro，系统最低版本为 iOS 27.0。`PathSense-技术路线-SLAM与VLM.md` 中的本机几何、地标身份和异步语义规划在这里配合工作。本轮指定的执行方式为一次只走一步。

## 在导航中检查什么

用户只说一次目的地。规划层保存最终目的地、当前中间任务、完成条件和所选地标。识别房间需要布局等独立证据。经过门后重新判断是在门口还是公共走廊。协议 v2 为各个目标标出来源帧和归一化框，最多带两张同一坐标系的历史照片。相机内参、图像方向和拍摄位姿用于恢复视线。只有经过多视角核对才保存空间位置。

转向和迈步使用不同证据。看到目标即可提示原地转动。迈步还要求身体朝向已确认，且连续三张不同的近期观察支持脚前、落脚和身体通过的范围。开始播放固定普通话短句前，手机读取相机的最新位姿与近场检测。播放位置开始推进后再记 `speechStarted`。风险、过期、偏离或任务变化会撤销许可。步长没有统一值，执行层根据连续前向位移和站稳判断本次动作结束。手持相机无法直接测量脚的落地，判断含糊时需要重新观察。

暂停本次导航，再在使用说明中分享记录。`plans` 记录规划引用的帧、框与地标，`stepEvents` 记录许可编号、观察帧、检查范围、运动偏移、播放开始或取消、撤销和结束。时间为会话内的单调时钟。`stops` 记录本机发现风险、申请提示和语音回调的时间。软件回调无法测量扬声器到耳朵的延迟或使用者的反应时间。

## 现场素材和复现

`Scripts/prepare-field-replay.py` 在本机从私有原片恢复回放输入，以来源、帧号、视频时间戳和 SHA-256 核对像素。`Scripts/navigation-field-replay.json` 记录 BSG21 录像和 BSG33 照片的来源。RTR 手机录像与照片可验证系统 OCR 和图像管线。这些视频没有同步 AR 位姿、深度、置信度或脚步标注。回放中的位姿、深度样本、部分检测框及通行结果均按测试说明注入。真实画面中的状态机通过不能单独证明手机在相同位置会识别出可通行路线。

```sh
python3 Scripts/prepare-field-replay.py
PATHSENSE_REAL_FRAMES_DIR="$PWD/.build-local/field-feedback/real-frames" swift test --scratch-path .build-local/core
python3 -m unittest discover -s Proxy
Scripts/replay-field.sh SIMULATOR_UDID
```

| 用户要求 | 可复核的位置 |
|---|---|
| 1–4，教室经侧过道和原出口去厕所、公共走廊、房号不覆盖状态 | `PlannerTaskTests`、`StepPermitReplayTests` 和正式规划入口。场景链的语义和位姿有受控注入。 |
| 5–6，框在右前约 30°，右转 60° 后向左；横移重新核对 | `SpatialReplayTests`、`StepPermitReplayTests`、模拟器迟到的代理回包。 |
| 7–10，看清目标仍须检查通行区，每步使用新观察，手抖和站定不算完成 | `GroundImageTests`、`LidarPassageTests`、`StepPermitReplayTests`；录像的两步回放另核对实际音频回调。 |
| 11–14，播放前取消、人员闯入、重听、急停后恢复有效读牌 | `StepPermitReplayTests`、`CueDeliveryTests` 和现场门牌、人员进入、两步行走的界面回放。 |
| 15–16，异步回包、离线、暂停、追踪重置、远处目标及绕行身份 | `PlannerTaskTests`、`SpatialReplayTests`、`StepPermitReplayTests`、模拟器绕行及暂停用例。 |

## iPhone 17 Pro 云端连接

Release 1.0（14）修复了构建 13 缺少设备授权的问题。真机使用硬件生成的密钥注册，重启 App 后保留授权。2026 年 11 月 22 日，iPhone 17 Pro 在 Mac 演示代理暂停时，两次用内置实拍门照直接向 DeepSeek 取得 HTTP 200 和匹配请求帧的规划。记录显示均为非蜂窝网络请求，未经过系统代理。耗时为 2.150 秒和 2.676 秒。蜂窝与拔线场景尚未单独测试。[两次真机回执摘要](../.build-local/navigation-step-pro/cloud14/public-result.json)

已配置直连时，使用说明显示连接方式及测试按钮。点击「用公开门照测试连接」只发送内置的 CC0 实拍门照和测试位姿。手机须收到对应帧号并成功解析规划，才能显示测试成功。发送现场关键帧另由「启用云端视觉」的确认控制。

## 2026 年 11 月 22 日验证结果

| 验证环境 | 实际结果与证据 |
|---|---|
| 构建 | 1.0 (13) 的模拟器 Debug 和签名真机 Release 均通过。真机安装查询返回 1.0 (13)。产物包含新图标、公开门照和直连模型的客户端。见[真机版本查询](../.build-local/navigation-step-pro/installed-13-version.json)、[Debug 构建日志](../.build-local/navigation-step-pro/debug-direct-13.log)和[Release 构建日志](../.build-local/navigation-step-pro/release-independent-cloud.log)。 |
| Mac 自动化回放 | 核心测试 147/147 通过。加入直连协议回归后，代理及协议测试 16/16 通过。现场照片的系统 OCR 识别出 `BSG33` 和 `ROOM - BSG33`。读取这张牌后，最终目的地仍为洗手间，规划器仍将所在场景标为未知。见[核心测试](../.build-local/navigation-step-pro/core-tests.log)、[代理及协议测试](../.build-local/navigation-step-pro/proxy-tests-direct.log)和[照片 OCR](../.build-local/navigation-step-pro/mac-original-photo-vision.json)。 |
| iPhone 18 Pro 模拟器 | 同一段回放中，执行层接受了两份不同的许可，`AVAudioPlayer` 两次开始播放「向前迈一步」。第一声使用源录像第 2757、2763、2769 帧。模拟用户站稳后重新观察，第二声使用第 3144、3147、3150 帧。两次最新检查距开播分别约 102 和 105 毫秒。冻结画面后，第二份许可被撤销。JPEG、帧号和时间戳来自原录像，位姿、门框和通行证据由测试注入。本次回放不运行 Vision。见[逐帧校验](../.build-local/navigation-step-pro/direct-03/validated.json)和[许可与播报记录](../.build-local/navigation-step-pro/direct-03/walk-measures.json)。 |
| 模拟器界面测试 | 较早版本在 Pro 上运行了 20 项，12 项通过、7 项失败、1 项跳过。后续一次 XCTest 运行器在进入用例前退出，另两次运行被中断。两步直接回放已单独通过，整套界面测试仍待重新通过。见[各次运行及用例结果](../.build-local/navigation-step-pro/simulator-evidence-index.json)。 |
| iPhone 17 Pro 静置 | 一次真机诊断采到 674 个位姿、98 次近场检查和 19 个关键观察，并记录普通话完成、对准轻震与急停双震回调。另一次采样的 586 次近场检查中有 583 次收到深度及置信图，前方区域全部判为未知，未发前进指令。现场听感、实际脚步和完整的教室至厕所路线尚未进行陪同实走验证。见[真机诊断](../.build-local/navigation-step-pro/device-check.json)和[真机深度采样](../.build-local/navigation-step-pro/pro-live-depth.json)。 |

## 陪同实走

请在 BSG21 室内说「带我去厕所」，也在已知公共走廊开始一轮。由陪同人员核对每次「向前迈一步」时实际脚前净空，记录漏报、误报、走完后何时听到下一条提示，以及跨门后是否继续寻找厕所。遇到无法确定的区域，留在原地核对。暂停后导出记录，与陪同人员观察的时间对齐。使用者的听感、震感、实际步长和实走到达率均须在现场记录。
