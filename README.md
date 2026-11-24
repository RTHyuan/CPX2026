# PathSense｜面向盲人和低视力人士的室内语音导航系统

PathSense 是一款面向盲人和低视力人士的 iPhone 室内语音导航应用，旨在从用户说出或输入目的地开始，经过多个连续的导航阶段，引导用户抵达并核实自己要去的地方。在建筑内部，判断下一步往哪里走所需的信息往往分散在沿途的导览目录、方向标识和入口标牌上。PathSense 通过手机相机识别与目的地有关的线索，结合用户朝向和近处通道的情况，用简短的中文或英文语音提示用户何时转向、向前走或停下。用户移动后，系统依据新的现场观测更新下一项指引，同时保留最终目的地和已经核实的路线信息。这套多阶段导航设计面向跨楼层及其他复杂室内场景，完整行程的最后一个环节是核对目标入口，并由用户确认到达。

为了让前后两次指引连得起来，PathSense 在多阶段导航中分别记录**最终目的地、当前子任务和已经核实的线索**。最终目的地决定整段行程要去哪里，当前子任务决定此刻需要寻找什么，以及满足什么条件才能继续。不同线索能回答的问题也不同：导览目录可以提供目标所在的楼层，方向牌上的名称和箭头可以提供下一段的行进方向，入口标识可以帮助核对眼前的地点。即使沿途已经读到目的地名称，系统仍需在目标入口核对地点身份，并结合接近情况或用户确认，才能将行程标记为完成。

在实际交互中，云端视觉模型结合当前相机画面、用户目的地和最近的提示，判断眼前哪些信息与下一步有关。模型返回一条简短的场景描述、一项建议动作，以及该动作所依据的门、通道或路口在画面中的位置。提示词明确面向盲人和低视力用户，要求每次只描述与导航有关的可见事实，只给一个动作。读到标识时，需要核对设施名称与箭头的对应关系；需要补充观察时，要说明应把镜头转向哪里。场景描述和动作文字由模型按所选语言当次生成，再由 iPhone 合成为中文或英文语音。用户可以暂停或重听。

**何时主动提示向前走，由现场视觉和手机的近距离空间观测共同决定。** 模型负责辨认该朝哪个目标前进，iPhone 则利用 ARKit 跟踪手机的位置和朝向，检查脚前地面、落脚区域以及身体前方是否有足够空间。只有目标仍与当前视野一致、近处通行条件也满足时，应用才播报前进指引。用户转向或移动后，系统依据新的观测决定下一步。若相机跟踪中断、目标已偏离视野或前方出现障碍，先前的前进判断随即失效。支持 LiDAR 的设备还可以记录局部深度点云，并与移动轨迹、已观测地标一起在 Mac 上查看，以便复核手机当时看到了什么、在何处作出了判断。

**当前版本的能力与验证范围。** 默认模式已支持实时环境描述、标识与方向识读，以及引导用户接近当前可辨认的门口。开发模式已通过受控画面回放检验跨楼层任务的阶段切换，包括保留最终目的地、核对楼层和辨认目标入口。真机测试已验证短时轨迹与 LiDAR 点云的采集、导出和显示。整栋建筑内任意起终点的路线规划、行进中的持续定位与偏航纠正，以及最终到达核验，仍未形成完整可用的导航流程。面向盲人及低视力用户的实地全程验证也尚未完成。

*PathSense is a voice-guided indoor navigation app for iPhone, designed for people who are blind or have low vision. Its goal is to guide the user through successive stages of a journey to a chosen destination, including routes across floors. The current app describes the scene, reads directional signs and guides the user toward a visible doorway in English or Chinese. Multi-floor stage transitions have been tested in controlled replay. End-to-end navigation between arbitrary indoor locations remains in development.*

## 项目后记

PathSense 是我们参加 [CrossPointX 2026 校际黑客松](https://cpx2026.devpost.com/)的小组作品。在约 24 小时的开发时间里，我们完成了从需求探索、方案设计到 iPhone 真机原型的实现。受时间与开发经验所限，当时的参赛版本 1.0（18）仍有不少不足，例如在某些场景下无法及时提供前进引导，连续导航的完整性与稳定性也有待完善。

这次参赛也留下了一些遗憾。在约三分钟的现场讲解与演示中，我们没有使用幻灯片，而是希望直接展示已经安装在 iPhone 上、能够实际运行的 App——这是我们最希望被看见的成果。但从团队的现场感受来看，讲解与真机演示未能得到充分关注，作品的实际运行情况和我们投入其中的思考，也未能充分传达。这让我们感到失落。

比赛之外，我们仍然希望这个想法能够继续生长。项目受到 Apple Swift Student Challenge 获奖作品 [Asuo — 在泛洪区发现安全的逃生实时路线](https://www.apple.com.cn/newsroom/2026/05/ai-meets-accessibility-in-this-years-swift-student-challenge/) 的启发。我们由此开始思考，能否让室内环境中依赖视觉获取的方向信息，转化为盲人和低视力人士能够使用的行动指引。

在现实场景的模拟测试中，我们更具体地意识到：寻找入口、辨认标识、确认方向，这些对明眼人而言往往不经意的动作，在缺少视觉信息时可能成为一道道障碍。团队的模拟体验无法代替视障使用者的真实经历，但它让我们更加确信，这个需求值得被认真对待，也值得与真正的使用者一起继续探索。

我们将项目开源，希望有兴趣、有能力的开发者、设计师、无障碍实践者与使用者参与进来，共同完善它，推动它走向真实可用的产品。如果这份尝试能够为视障人士的室内自主出行提供一点帮助，或为后续的解决方案带来一点启发，那就是这个项目带给我们最大的收获。

如有交流或合作需要，欢迎通过本仓库的 Issues 联系我们。我们十分乐意分享已有的开发经验、测试观察和设计思路，并在力所能及的范围内提供帮助。

**有爱，无碍。**

## 在手机上使用

1. 在首页选择中文或 English，说出或输入想找的地方。也可以保留默认的「门口」，点「开始导航」。
2. 站稳，将后置镜头朝向身体前方。手机先描述它能辨认的门、过道或标识。看不清箭头时，它会说明方向不清。
3. 听到转向提示时先原地转向。只有手机检查过眼前的落脚处和身体前方的空间，才会提示向前走。你可以随时重听、暂停，或在门口结束。

导航时请继续使用自己惯用的白杖、导盲犬或陪同支持。详见[使用说明](docs/door-demo.md)。

导航期间，iPhone 会把选中的相机画面、目的地和最近提示发送给配置的云端视觉服务。暂停、结束或切到后台会停止新的采集和发送。

## 从源码运行

用 Xcode 27.2 打开 `PathSense.xcodeproj`，选择 `PathSense` scheme、自己的开发团队和一台运行 iOS 27.0 或更高版本的 iPhone。构建安装后先解锁并打开一次应用。相机用于观察现场，麦克风和语音识别用于口述目的地，也可以用键盘输入。

实时识图需要联网和开发者自行配置的视觉服务凭据。在 Mac 上配置 `PATHSENSE_DEVICE_DEEPSEEK_API_KEY`，运行 `xcrun devicectl list devices` 找到已配对的手机，再运行下面的命令，将设备标识替换为自己的值。手机把凭据保存在钥匙串中。[配置与开发交接](docs/handoff.md)

```sh
python3 Scripts/enroll-device-cloud.py --device YOUR_DEVICE_ID
```

## 查看局部地图

PathSense 可以把一次观察中的移动轨迹和地标导出为 JSON。支持 LiDAR 的 iPhone Pro 还可以记录局部深度点云。在导航页展开「局部地图」并分享文件。Mac 上运行以下命令，打开终端显示的本机地址，导入刚才的 JSON 即可查看。三张扫描楼层图可作为参考，尚未与手机位置自动对齐。[Mac 查看器与 USB 操作](MappingData/Mac查看器.md)

```sh
python3 Scripts/map-viewer.py
```

## 开发与验证

默认导航入口在 `App/DoorDemoSession.swift`。中英文提示词约束每次只描述可见事实、给出一个动作。`Core/DemoGuide.swift` 校验模型回复是否对应当前画面，`Core/StepExecution.swift` 管理单步提示的起播与失效。[中文提示词](App/Resources/deepseek-demo-v1.txt) · [英文提示词](App/Resources/deepseek-demo-en-v1.txt)

```sh
swift test --scratch-path .build-local/core
python3 -m unittest discover -s Proxy
```

已有一段 iPhone Pro 实测轨迹和 212 个 LiDAR 点的短采集，可在 Mac 查看。更长距离的漂移、动态障碍和连续导航需要进一步实测。仓库提供了各次测试的数据来源、运行方法和适用范围。[验证记录](docs/delivery-19.md) · [项目交接](docs/handoff.md) · [目录与容量说明](docs/directory-inventory-20261122.md)

源码采用 Apache License 2.0。摄影、扫描底图与测试素材的来源见对应说明。[许可证](LICENSE) · [素材来源](ASSET-CREDITS.md) · [楼层扫描说明](MappingData/floorplans/README.md)
