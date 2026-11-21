# PathSense · Devpost 文案与 90 秒桌面演示

## 项目名和简述

**PathSense · 室内寻路**  
**Track One · Apple Human-Centered Care**

**中文简述**　用户在房间、医院门口或商场入口输入想去的地方。手机从现场的门、目录、楼层和路牌中找线索，每到路口给出下一步，直到使用者核对独立门牌或店招。

**English tagline**　Find a room, department or shop by reading the signs around you, one stop at a time.

### Inspiration

People with low vision often need to stop at a doorway or junction to read visual directions. A directory entry, a landing sign and a plaque at the final destination each answer a different question.

### What it does

The traveler enters a destination in their own words. The phone surveys the view for a door or entrance, remembers a nearby room number, pairs the destination with a floor or arrow on the same sign row, then checks landing signs and the final room plate or storefront. The app can read directions to a lift or stairs, request clarification when names are similar, repeat a cue and start again from a new position. The user checks passage and confirms arrival.

### How we built it

SwiftUI and AVFoundation provide the interface and camera. Apple Vision returns text, bounding boxes and scene observations. A second image scale helps confirm low-confidence spellings. Geometric checks recover certain printed arrow shapes and doorway outlines. The route follows a destination-independent sequence of observations and remembers floor and zone evidence. Successive camera frames must agree on the floor, direction and sign context before the cue changes. A small Core ML classifier contributes evidence about lists. OCR and the journey run on the device.

### What we tested and learned

Three continuous pixel-buffer sequences covered a campus room, a hospital department and a mall store. A fourth name appeared only on external test images. The app correctly associated it with floor 6 and the left arrow on a two-row sign. A real photograph of an unlabelled door and a blank image exercised scene recognition. The continuous campus sequence covered room 208, a floor directory, a lift sign, a landing, a corridor sign and room 402. On an iPhone Air simulator, the traveler went from the door photograph to confirming room 402. The exhibit shows build 8 on the simulator with a labeled camera replay. Field travel, VoiceOver listening and haptic feedback still need in-person observations.

### Tools and attribution

Codex assisted with implementation, tests and documentation. We used Xcode, SwiftUI, AVFoundation, Vision, Core ML, Create ML, UIKit and XCTest. We generated the practice sign images and app icon using Pillow and constructed the layout training examples. We used an actual screenshot from the app’s simulator run and laid out the exhibit poster in ReportLab. The door photograph is by Samuel Zeller under CC0. The project source code is licensed under Apache 2.0.

**海报素材披露**　本次展桌版使用项目自己的应用截图和排版。需要填写生成证明时，按实际素材和主办方答复办理。

**四人贡献字段**　将四名正式参赛成员逐一添加到 Devpost，根据各人已经发生的参与各写一句，可以是共同讨论、现场试用或展示中作出的具体贡献。现阶段没有代填姓名或贡献。

## 展桌讲稿 · 约 90 秒

| 时间 | 展示动作 | 可以直接说的话 |
|---|---|---|
| 0–15 秒 | 首页输入 402，点「开始导航」，开启后置相机。 | “我知道要去 402，但刚进这栋楼。我先站定，转动手机寻找门或指示牌。” |
| 15–32 秒 | 站定并转向门，通过后确认，再扫 208。 | “手机在画面中央标出疑似门的方向。通过后，我扫到刚离开的房号 208。接下来要看楼层目录。” |
| 32–55 秒 | 扫目录和换层指示，再扫四楼的楼层牌。 | “目录将 401 到 420 列在四楼。电梯指示朝右。到站后读到 4F，才开始在这一层找。” |
| 55–72 秒 | 扫走廊路牌、独立门牌，确认到达。 | “路口的箭头指向左边。独立门牌写着 402，我核对后确认到达。” |
| 72–90 秒 | 请评委输入其他名称，把后置镜头转向另一块标牌。 | “医院科室和商场店招走同一套识别。导览牌上出现两个相近名称时，使用者可以选择。欢迎用另一块路牌试试。” |

展台保留[构建 8 的连续导航界面与回放](../docs/index.html)。

## 提交顺序 · 北京时间

1. **现场试用。** iPhone Air（iOS 27.2.1）已安装构建 8。首次试用时请解锁，并按系统提示联网验证开发者。站定后依次扫描房号、区间和相似门牌。开启 VoiceOver，记录实际听感、触觉和时延。[实地验证记录](实地验证.md)
2. **展桌海报。** A3 PDF 可直接打印，PNG 可供投屏。核心画面来自构建 8 的持续扫描模拟器实录。赛事规则另要求 AMD 原图和同一作品的 Gallery 截图。当前版缺少这两项，正式交件前向主办方核对是否接受实录海报，保留答复。[A3 PDF](../output/pdf/PathSense-poster.pdf) · [PNG](../output/pdf/PathSense-poster.png) · [正式规则](https://cpx2026.devpost.com/rules)
3. **公共访问入口。** 构建 8 的源码、寻路截图、连续回放实录、字幕、打印标牌和截图版海报已打入本地交付包。取得团队授权的远程仓库后发布这版源码，保存真实仓库及演示地址。GitHub Pages 可以从 `/docs` 发布。[公开源码包](../output/PathSense-public-source.zip) · [GitHub Pages 说明](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
4. **填写 Devpost。** 建一个方向一项目，列入四名正式成员，填写项目简介、实际贡献和工具披露。粘贴演示与源码地址。按照主办方对海报的答复处理图片、PDF 及证明字段。
5. **验收并提交。** 用无痕窗口播放演示、切换字幕，打开源码、海报和主办方接受的材料。内部目标为北京时间 **2026 年 11 月 22 日 12:00**，官方截止为同日 **13:00**。提交后保存平台回执与时间。[活动概览](https://cpx2026.devpost.com/) · [正式规则](https://cpx2026.devpost.com/rules)
