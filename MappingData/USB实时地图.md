# 通过 USB 在 Mac 查看实时地图

先在 Mac 启动本项目的地图查看器，保持 iPhone 已连接、已配对且可供开发工具访问，然后运行：

```sh
python3 Scripts/watch-map-usb.py --device 00008150-001E481E1183C01C
```

脚本默认每 3 秒通过 `xcrun devicectl` 读取 `org.crosspointx.pathsense` 容器内的 `Documents/LocalMaps/PathSense-live-map.json`，解析 JSON 后 POST 到 `http://127.0.0.1:8765/frame`。App 负责自动保存快照；脚本不会启动、安装或重启 App。

默认设备标识是此次 Pro 设备。连接其他手机时显式指定其完整标识。可用 `--url` 修改本机查看器端口或路径，`--interval` 修改间隔，`--once` 仅传送一次（成功退出码 0，失败为 1）。`--help` 查看参数。

仅允许 `localhost` 或 `127.0.0.1` 的 HTTP(S) 地址，忽略系统代理并拒绝重定向。快照尚未保存、设备断开或查看器未启动时会温和重试。按 Ctrl+C 结束；只清理脚本创建的临时副本，保留手机和项目内的用户文件。

这里显示的是 App 实际记录的数据。楼层扫描图与本次 AR 会话尚未配准时应分别查看；不要把扫描图的红星当作手机位置。
