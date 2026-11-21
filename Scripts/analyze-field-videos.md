# 现场视频抽帧与复核

在工程根目录运行。需要 Python 3、macOS 和本机的 Xcode Command Line Tools。Python 入口用标准库调用 AVFoundation，直接读取「照片」中的本地文件。每次成功运行会在 `Submission/private/field-videos/runs/` 建立独立报告。

```sh
python3 Scripts/analyze-field-videos.py status
python3 Scripts/analyze-field-videos.py run --interval 1
```

`status` 记录文件清单、说明原文、说明的 SHA-256 和对应状态。`run` 在等待说明或材料时以状态码 2 结束。说明中点名的素材对应完成后，`run` 输出报告位置。间隔以秒计，例如 `--interval 1/2`。需要更细的事件时间时，可以缩小间隔，再从原片确认事件出现的第一帧。

## 按说明对应来源

- 用户在说明中按文件名点名素材时，脚本按文件名出现的次序对应，逐片保存说明摘录。既有录像 `视频-zhx.mp4` 在清单中单列。
- 用户只描述场景时，复核人先在本机看候选新片，找出与描述相符的动作、场景或设备画面，再把对应结果写进私有目录的 `bindings.json`。说明仍使用用户写的原文。新说明的 SHA-256 可从 `status.json` 读取。
- `bindings.json` 的顶层字段为 `info_sha256` 和 `clips`。`clips` 按说明实际列出的文件逐项填写，每条的 `original` 为相对于「照片」的原文件路径，`info_quote` 为说明逐字摘录，`match_basis` 记录对应线索。说明更新后，重新核对引用与素材。

## 核对一帧

打开报告中的逐片 CSV。`frame_index` 是按呈现顺序从零计的源帧编号。`pts_value / pts_timescale` 是可在影片时间线上复现的显示时间，`sample_pts_value / sample_pts_timescale` 是编码样本的原时间。含剪辑、裁切或起始空段的容器可能产生不同的数值。

`target_elapsed_seconds` 是从首个可显示帧起算的目标采样时刻。脚本选取位于该时刻或之后的第一帧，并保留片尾可显示帧。`elapsed_seconds` 记录实际选中帧的相对时间，`previous_gap_seconds` 记录与上一个样本之间的实际间隔。变帧率和片尾会使实际间隔变化。

每片的 `frames.json` 同时保存原名、来源与各张 JPEG 的 SHA-256、编码尺寸、JPEG 尺寸、影片时长、视频轨起始时间与时长、音轨信息及显示方向变换。`frames/` 中的 JPEG 采用影片的显示方向。

```sh
python3 Scripts/analyze-field-videos.py verify --run-id 运行目录名
```

核验会重新计算原片和全部 JPEG 的 SHA-256，逐行对照 CSV 与 JSON，并从每段片的 CSV 选一个时间戳回到原片重解码。选择由原片哈希决定，优先抽取中间帧。重解码的 JPEG 与归档图逐字节相符时，结果写入 `verification.json`。JPEG 字节复现基于同一系统解码、编码环境，运行时的系统和脚本版本记录在 `manifest.json`。

每片的 `review.md` 链接开头、中间和结尾的样本。复核人按说明补看相关动作前后，记录可见内容和 PTS。有可辨声音时，在同一影片时间线上记录起止和所听内容。画面事件之间的可见时间差可据帧记录。AR 位姿需要跟踪数据，端到端提示延迟需要同一时间基准下的触发与输出记录。

## 按说明时间核对

以原文件名独立成行开启该片的标注段。每条标注写作 `分:秒｜位置｜内容`，秒可含小数，缩进的下一行接续同一条标注。脚本按影片时间选取位于指定时间或之后的第一帧。该帧同时落入全程采样时只保存一张 JPEG。CSV 的 `annotation_ids` 对应逐片 JSON 中的说明序号。

本次实拍的入口在 `Submission/private/field-videos/LATEST.md`。逐片复核页含画面时间线、逐项备注、原尺寸 JPEG 与全片采样拼图。复核记录同时归档为 `annotations.csv` 和 `annotations.json`。

重跑后可以按新报告的运行编号关联原有目视记录。关联时同时核对说明、原片和每张指定帧的 SHA-256。

```sh
python3 Scripts/analyze-field-videos.review.py 运行目录名
```

## 重建正式集成回放的八张实拍图

在工程根目录运行以下命令。每次都从「照片」里的两段原始 MP4 解码。首次运行或清理 `.build-local` 后，命令会建立目录并补齐八张 JPEG 和清单。

```sh
python3 Scripts/prepare-field-replay.py
```

基准清单原样保存了集成回放原始 `real-frames/manifest.json` 的文件名、请求与实际 PTS、尺寸和 JPEG SHA-256。[查看八帧基准清单](analyze-field-videos.replay.json)

文件名保留请求秒数。脚本先校验两段 MP4 的 SHA-256，再把每行 `actual.value` 和 `actual.timescale` 两个整数传给现有原生读取器的 `frame` 模式。读取器以零时间容差请求该帧，并核对 AVFoundation 返回的实际 PTS。

| 回放文件 | 请求（秒） | 回放使用的实际 PTS | 现场报告对应帧（秒） |
|---|---:|---:|---:|
| `rtr1-66.0.jpg` | 66.0 | 5938515/90000 = 65.9835 秒 | 66.016833 |
| `rtr1-70.2.jpg` | 70.2 | 6316515/90000 = 70.1835 秒 | 70.216833 |

脚本在临时目录抽齐八张，逐张校验尺寸与 SHA-256，全部通过后写入 `.build-local/field-feedback/real-frames/`。若输出目录已有 `manifest.json`，脚本会先与基准清单核对。命令最后从输出目录重读每张 JPEG，打印文件名、实际 PTS 与完整 SHA-256。成功时末行显示 `8/8`，校验失败时返回非零退出码。

2026-11-22 本机实测重建 8/8 张。另用 `shasum -a 256 -c` 读取最终目录，八个文件全部匹配原清单。`sips` 确认八张均为 720 × 1280 的 JPEG。若受限沙箱的 AVFoundation 报 `Cannot Decode`（`-12911`），可在本机终端运行同一条命令以使用系统视频解码服务。
