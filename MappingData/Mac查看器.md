# Mac 地图查看器

本工具展示 iPhone 实际导出的局部地图，不生成虚拟扫描数据。VIO 轨迹、定位地标、点云与扫描楼层底图分开展示。AR 会话坐标未与扫描楼层图自动配准；手动叠加只是显示预览，不能证明定位或通行。

## 离线查看

双击 `MappingData/viewer.html`，点“选择 App 地图 JSON”，导入手机导航页“局部地图 → 分享地图 JSON”得到的文件。点击“局部平面”或“三维点云”，拖动、缩放查看。手机导出没有 `points` 时只显示轨迹和地标，不补出点云。

“扫描楼层图”可切换随包提供的扫描底图，也可导入自己的图片。底图与 AR 地图具有不同坐标系；“叠加 AR 轨迹”通过像素/米、旋转和偏移手动摆放，默认关闭，不会改动导出的测量数据。

## 在浏览器跟随 Mac 文件

在项目根目录运行：

```sh
python3 Scripts/map-viewer.py --watch /你的/Mac地图导出目录
```

然后打开 `http://127.0.0.1:8765/`。服务器每秒随浏览器请求检查目录中修改时间最新的 JSON；也可在网页下拉菜单选择一个文件。将 iPhone 的最新导出文件通过分享或 USB 拷入该目录，网页即更新。单文件模式：

```sh
python3 Scripts/map-viewer.py --json /你的/PathSense-local-map.json
```

此模式是查看导出文件，不代表 App 正在持续向 Mac 直播。服务器默认只绑定本机回环地址，不读取或发布项目其它文件。

## 通过 USB 跟随 iPhone

手机已配对、解锁并信任这台 Mac 后，在手机开启导航，让 App 持续记录地图。项目根目录分别打开两个终端运行：

```sh
python3 Scripts/map-viewer.py
```

```sh
python3 Scripts/watch-map-usb.py
```

浏览器打开 `http://127.0.0.1:8765/`，保持勾选“跟随 Mac 文件 / HTTP 接收”。App 每约 3 秒原子写出 `PathSense-live-map.json`，第二条命令通过 USB 拉取并交给本机查看器；实际更新速度取决于设备连接和复制耗时。手机应保持导航运行在前台。拉取失败会在终端报告，不会生成替代地图。其它已配对设备可使用 `--device 设备标识` 指定。

只载入一个已有真实导出文件且不跟随修改，可运行 `python3 Scripts/map-viewer.py --file /你的/PathSense-local-map.json`。

## 可选 HTTP 帧输入

已有真实采集端时，可向 `POST /frame` 发送以下任一种格式。`path` 沿用 App `LocalMapSnapshot.path`，点坐标为米，`points` 恰为 `[[x,y,z], ...]`：

```text
{ ...App 的 LocalMapSnapshot 字段..., "points": [[x,y,z]], "pointSource": "lidar_depth" }

或

{ "snapshot": { ...App 的 LocalMapSnapshot 字段... }, "points": [[x,y,z]], "pointSource": "visual_features" }
```

以上为字段形状说明，不是实测样本。默认将每个完整 snapshot 替换当前画面；App 的轨迹和点云已自行累计，空 snapshot 会清空旧地图，过期地标不会残留。只有在顶层明确给出 `"mode": "append"` 时才按增量合并；该模式仅合并相同 `session/world`，坐标世界改变会清空旧累积，点云以 8 厘米体素去重。最多保留 120,000 点、10,000 个轨迹点。

如需让同一可信局域网中的 iPhone 发帧，必须显式打开局域网监听：

```sh
python3 Scripts/map-viewer.py --host 0.0.0.0 --port 8765 --token '自行设置的临时口令'
```

采集端使用 Mac 局域网 IP，发送时带 `X-Map-Token` 请求头。`GET /state` 返回当前数据，`GET /download.json` 导出当前记录。`GET /data?file=文件名.json` 只读取 `--watch` 目录内的 JSON。当前 App 可通过 USB 拉取脚本或导出 JSON 使用本工具；LAN HTTP 接收需要采集端另行发送。

## 数据含义

- `path`：ARKit VIO 相机位姿的实际记录，不是规划路线。
- `landmarks[].point`：已有坐标的地标；只有 `bearing` 而没有 `point` 的地标仅计数，不绘制假定坐标。
- `points`：可选实测观测点。`lidar_depth` 为深度来源，`visual_features` 为视觉特征来源；视觉点不等同于稠密激光扫描。
- 扫描楼层图：图片底图，没有自动地理配准、障碍识别或实时可通行保证。
- 各次 AR 会话的局部坐标不能直接拼接为整栋楼地图。
