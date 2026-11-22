# 建图数据

`floorplans/` 包含用户已提供的真实 BS 楼层导览牌扫描图，图面楼层为 **LEVEL G、LEVEL 1、LEVEL 2**。原图按字节保留，尺寸、来源和校验值见 `floorplans/manifest.json`，接入与坐标限制见 `floorplans/README.md`。

`floor-reference-example.json` 是原有楼层拓扑测试样例（来源：`Tests/Fixtures/demo-floor.json`），含标签节点、平面坐标和可通行边。它不是这栋楼的实测地图。

实际局部地图由 App 根据 ARKit 位姿、当前近场观察和地标记录生成，可在导航页“局部地图”内导出 JSON，暂停或结束时也会保存到 iPhone 的 `Documents/LocalMaps/`。数据仅在各自 AR 会话坐标系内有效；不能凭不同会话的数据直接拼接全楼地图。地图记录不替代实时行走检查。
