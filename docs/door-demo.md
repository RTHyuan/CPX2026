# 室内寻路：中英文 DS 演示

默认首页为“室内寻路”（英文为“Indoor Navigation”），沿用原目的地、常用设施、最近目标与语音开关界面，实际由新的 DS 简要引导控制器运行。可说出或输入目的地，点“开始导航”。默认目标为门口；本演示到可识别门口即结束。到门口可点“我已到门口，结束”；连续观察与实际接近满足条件时也会结束。首页下方可切换“中文 / English”，选择会保存，运行中需返回首页才能切换。

DS 每次接收当前完整照片，返回一段不超过 32 字的场景描述和一段不超过 24 字的动作。提示词明确用户是盲人，一次只给一个动作，看到路牌时描述清楚可辨认的设施与箭头方向，门或通道明确时主动转向或向前一步。看不清方向时不得猜测。

中英文界面与语音均使用对应语言的 DS 原文。英文不是本机翻译中文回包：请求使用独立英文提示词，DS 直接返回不超过 120 字符的场景和 90 字符的动作，英语单步必须明确 one step / one small step。兼容字段名 scene_zh / speech_zh 保留，英文模式的内容必须为英文。英文听写使用设备端英语识别，英语声音优先 en-US。切换语言会停止旧音频并清理旧句子；界面按钮、取景、停步和权限错误提示同步切换。

场景和转向句由手机实时 TTS 朗读；单步句也按每次 DS 原文实时合成临时音频，等本机单步许可通过后播放。演示的行走句使用实时模型原句。关闭语音后不会自动播出单步指令，可点“重听”请求当前这一小步。紧急停步、权限与取景提示来自本机。

前进仍需要新鲜的脚前地面、落脚区域和身体空间证据，以及手机与身体朝向确认。每个 DS 回包最多授权一次短单步；走完并站稳后重新识图。向下补看脚前地面不会仅因俯仰变化丢弃门的方向；换世界、超时、偏离位置、转向过多、障碍、暂停或后台会使旧动作失效。只拿一张照片不能产生行走许可。

主要实现：`App/DoorDemoSession.swift`、`App/DoorDemoView.swift`、`Core/DemoGuide.swift`。提示词在 `App/Resources/deepseek-demo-v1.txt` 和 `App/Resources/deepseek-demo-en-v1.txt`。右上角为中英文使用说明。旧完整导航仍可用启动参数 `--full-navigation` 打开。

开发验证参数 `--check-door-demo`（中文）或 `--check-door-demo-english`（英文）使用包内公开门照，运行生产请求、生产解析及当前模型单步句的静默实时合成，保存 `Library/Caches/PathSense-DoorDemoCloudCheck.json`，并分别保存 `PathSense-DoorDemoCloudCheck-zh.json` / `PathSense-DoorDemoCloudCheck-en.json`。此检查使用注入位姿，不打开相机，也不播放行走指令。Core 测试和受控控制器回放与实际传感器、实地步行的验证范围不同。

## 局部地图与数据导出

版本 1.0（19）在导航页加入局部地图，可查看本次会话的 ARKit 位姿轨迹、具有三角化坐标的地标和最新近场扇区；只有方向的地标保留方向数据，不编造坐标。地图坐标单位为米，采用 ARKit 会话坐标系；追踪重建或恢复相机会开始新的坐标段，不能将两段直接拼成完整楼层图。用户提供的 LEVEL G、LEVEL 1、LEVEL 2 三张真实扫描楼层图已原样收入 `MappingData/floorplans/`，尚未与实时会话做配准。

近场扇区仅在同一视向、位置且不超过 0.65 秒时显示，暂停、结束或跟踪中断立即清除。历史地图仅用于观察和导出，不为前进提供许可。暂停或结束会把本次数据保存到 iPhone 的 `Documents/LocalMaps/`，也可在局部地图内分享 JSON。文件包含位姿、采样轨迹、地标点或方向、最近观察与过期时间；不含相机照片和云端凭据。

源码包的 `MappingData/floor-reference-example.json` 是小型拓扑测试样例，源自 `Tests/Fixtures/demo-floor.json`，不是现场测量结果。

## Mac 点云与 VIO 查看

Pro 上采样 ARKit `sceneDepth` 的中高置信度深度点，反投影到同一 ARKit 世界坐标，0.2–5 米范围、每 0.5 秒采样，8 厘米体素去重，最多保留 24,000 点。无深度时明确标记为稀疏 `visual_features`，不会冒充 LiDAR 点云。导出 JSON 的 `points` 为 `[x,y,z]` 米制坐标，`pointSource` 表明来源；`path` 记录 ARKit VIO 轨迹。这是 ARKit VIO 加深度点云累积，未实现独立 LIO 优化、回环或全局楼层定位。

运行 `python3 Scripts/map-viewer.py` 可在 Mac 本机查看 JSON、轨迹、点云和真实扫描底图。运行 `python3 Scripts/watch-map-usb.py --device <UDID>` 可通过 USB 每约 3 秒读取导航中的 `Documents/LocalMaps/PathSense-live-map.json` 并刷新查看器；完整步骤见 `MappingData/Mac查看器.md`。这条链路不上传照片或凭据。图像与局部米制坐标没有自动配准，原扫描图红星是导览牌位置。

开发验证参数 `--check-local-map` 会进行 8 秒传感器采集，不请求模型、不播报行走指令，保存 `Documents/LocalMaps/PathSense-device-capture.json` 和采集报告。此采集与实地导航走完全程的验证范围不同。
