# iPhone 17 Pro 一步导航验证

本轮针对正式工程 `PathSense.xcodeproj`，部署目标为 iPhone 17 Pro，系统最低版本为 iOS 27.0。`PathSense-技术路线-SLAM与VLM.md` 中的本机几何、地标身份和异步语义规划在这里配合工作。本轮指定的执行方式为一次只走一步。

## 在导航中检查什么

用户只说一次目的地。规划层保存最终目的地、当前中间任务、完成条件和所选地标。识别房间需要布局等独立证据。经过门后重新判断是在门口还是公共走廊。协议 v2 为各个目标标出来源帧和归一化框，最多带两张同一坐标系的历史照片。相机内参、图像方向和拍摄位姿用于恢复视线。只有经过多视角核对才保存空间位置。

转向和迈步使用不同证据。看到目标即可提示原地转动。迈步还要求身体朝向已确认，且连续三张不同的近期观察支持脚前、落脚和身体通过的范围。开始播放固定普通话短句前，手机读取相机的最新位姿与近场检测。播放位置开始推进后再记 `speechStarted`。风险、过期、偏离或任务变化会撤销许可。步长没有统一值，执行层根据连续前向位移和站稳判断本次动作结束。手持相机无法直接测量脚的落地，判断含糊时需要重新观察。

暂停本次导航，再在使用说明中分享记录。`plans` 记录规划引用的帧、框与地标，`stepEvents` 记录许可编号、观察帧、检查范围、运动偏移、播放开始或取消、撤销和结束。时间为会话内的单调时钟。`stops` 记录本机发现风险、申请提示和语音回调的时间。软件回调无法测量扬声器到耳朵的延迟或使用者的反应时间。

## 现场素材和复现

原始现场录像与照片需要由素材持有人另行提供，放在工程根目录的 `照片/`。`Scripts/prepare-field-replay.py` 在本机从私有原片恢复回放输入，以来源、帧号、视频时间戳和 SHA-256 核对像素。`Scripts/navigation-field-replay.json` 记录 BSG21 录像和 BSG33 照片的来源。RTR 手机录像与照片可验证系统 OCR 和图像管线。这些视频没有同步 AR 位姿、深度、置信度或脚步标注。回放中的位姿、深度样本、部分检测框及通行结果均按测试说明注入。真实画面中的状态机通过不能单独证明手机在相同位置会识别出可通行路线。

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

用公开门照自检时，手机向模型发送公开 CC0 照片和测试用位姿。成功的回复须通过协议解析并引用对应帧。现场关键帧由导航界面的发送许可控制。iPhone 17 Pro 用公开门照两次直连 DeepSeek，均收到 HTTP 200 和对应帧的模型回复，分别耗时 2.150 秒和 2.676 秒。两次均使用非蜂窝网络，未使用系统代理，Mac 演示代理在各次请求全程暂停。蜂窝网络与拔线使用尚未实测。 [本次与历史自检](../Verification/云端自检.json)

各环境结果和使用的注入数据见[验收记录](../Verification/验收说明.md)。

## 陪同实走

请在 BSG21 室内说「带我去厕所」，也在已知公共走廊开始一轮。由陪同人员核对每次「向前迈一步」时实际脚前净空，记录漏报、误报、走完后何时听到下一条提示，以及跨门后是否继续寻找厕所。遇到无法确定的区域，留在原地核对。暂停后导出记录，与陪同人员观察的时间对齐。使用者的听感、震感、实际步长和实走到达率均须在现场记录。
