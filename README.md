# Reading Line 1.4.0

Reading Line 是一个面向 KOReader 的复古铁路主题阅读空间，将阅读主页、书柜、阅读统计和封面陈列架整合到同一套界面中。

## 主要功能

- **阅读主页**：车站式主页、动态时钟、电量、当前阅读、最近停靠、本周线路、本月月台等信息。
- **七种主页看板**：正在阅读、最近停靠、本周线路、本月月台、阅读签、随机发车、票根笔记；可同时启用 1–4 个。
- **书柜**：从书籍封面裁切生成书脊；默认书脊宽度随本机总页数变化，并保留最小点击宽度。
- **陈列架**：按原始封面比例展示，包含书页厚度、轻微倾斜和电子墨水屏友好的阴影。
- **阅读统计**：日、周、月、年和单本阅读车票；时长直接读取 KOReader 自带“阅读统计”插件的数据。
- **跨设备统计**：按各设备自己的分页换算阅读页数，不把不同屏幕尺寸的原始页码直接相加。
- **文字字数统计**：对文字类书籍在后台建立正文字符索引；空白页、插图页和只有少量文字的页面不会按整页估算。
- **个性化**：导航页面显示与排序、字体、书柜布局、壁纸、立体度、书脊裁切和自定义书脊。
- **可选 WebDAV**：复用 KOReader 已配置的 WebDAV，同步自定义书脊图片。

## 兼容性

- 已在 Kindle Paperwhite 6（KPW6）和 Kindle Scribe 上实际适配。
- 布局按屏幕尺寸动态计算，理论上兼容其他 Kindle、Kobo 及 KOReader 支持的设备。
- 阅读统计功能需要启用 KOReader 自带的 **阅读统计 / Statistics** 插件。

## 安装

1. 下载 `ReadingLine-v1.4.0.zip` 并解压。
2. 将其中完整的 `readingline.koplugin` 文件夹复制到 KOReader 的 `plugins` 目录。
3. 完全退出并重新启动 KOReader。
4. 打开 KOReader 顶部菜单，在工具/插件菜单中找到 **Reading Line**。

常见安装位置：

- Kindle：`/mnt/us/koreader/plugins/readingline.koplugin`
- Kobo：`/.adds/koreader/plugins/readingline.koplugin`
- 其他设备：KOReader 程序目录下的 `plugins/readingline.koplugin`

安装完成后应满足下面的目录结构：

```text
koreader/
└── plugins/
    └── readingline.koplugin/
        ├── _meta.lua
        ├── main.lua
        ├── bookshelf.svg
        ├── simpleui_bridge.lua
        ├── spine_cloud.lua
        ├── spine_upload.lua
        └── train-icons-svg/
```

## 从旧版本升级

1. 退出 KOReader。
2. 用新版 `readingline.koplugin` 替换旧插件目录。
3. 如果曾使用旧插件 `simplebookshelf.koplugin`，请删除或移走该旧目录，不能同时保留两个副本。
4. 重新启动 KOReader。

插件设置保存在 KOReader 设置目录的 `simplebookshelf.lua` 中。沿用这个历史文件名是为了兼容旧版本，正常升级不会清空书柜样式、导航顺序或统计设置。

## 基本操作

### 打开与关闭

- 在 KOReader 菜单中点击 **Reading Line** 可启用或停用插件。
- 长按 **Reading Line** 可按当前状态打开或关闭界面；关闭后会执行一次全屏刷新。
- 在 Reading Line 顶部区域点击或下拉，仍可调出 KOReader 菜单。

### 底部导航

默认包含四页：

1. 阅读主页
2. 书柜
3. 统计
4. 陈列架

进入 `Reading Line → 导航栏` 可勾选显示的页面；进入 `导航顺序`，使用每项旁边的 `↑`、`↓` 排序。至少保留一个页面。

长按某个底部导航按钮，会打开该页面对应的设置：

- 阅读主页：选择 1–4 个主页看板。
- 书柜：布局、立体度、书籍文件夹、壁纸、字号和字距。
- 统计：字体及统计票页面选择。
- 陈列架：层数、封面大小、间距、立体度和独立壁纸。

## 书柜

- 默认扫描 KOReader 当前书库，也可在 `书柜设置 → 全局默认 → 书籍文件夹` 中选择其他目录。
- 默认书脊宽度按本机分页连续计算：150 页以内采用保底宽度，之后随页数逐渐增厚。
- 长按书籍可编辑标题、尺寸、圆角、文字位置、裁切位置和自定义书脊。
- 手动设置书脊宽度后，该书不再跟随自动页数宽度；选择 `宽度 → 自动 · 按页数` 可恢复自动模式。
- 单击/双击打开方式可在 KOReader 的 Reading Line 菜单中切换。

## 阅读主页

- 长按底部“阅读主页”导航按钮，选择要显示的看板。
- “继续阅读”跳转到当前书籍。
- “随机发车”从书库中随机选择书籍。
- “票根笔记”读取书籍划线与笔记；点击标题查看完整笔记。
- “阅读签”轮播划线内容；长按可删除误划线。
- 动态数据与封面来自本机书库和 KOReader 阅读统计数据库。

## 阅读统计与跨设备同步

Reading Line 不维护另一套阅读时长，而是读取 KOReader 自带阅读统计插件的 `statistics.sqlite3`。

跨设备时建议：

1. 先退出正在阅读的书，确保本次记录已经写入统计数据库。
2. 在设备 A 的阅读统计插件中执行“立即同步”。
3. 等完成后，在设备 B 执行“立即同步”。
4. 再回到设备 A 同步一次，使两端都取得完整合并结果。

不同设备每页字数不同，因此 Reading Line 会根据每条记录的来源总页数与当前设备总页数换算显示页数。文字类书籍的字数会在后台逐页提取正文字符；索引尚未完成时会暂用兼容估算值。

## 壁纸与自定义书脊

- 书柜与陈列架各自拥有独立壁纸和填充方式。
- 默认壁纸目录位于 KOReader 设置目录的 `simplebookshelf/wallpapers` 与 `simplebookshelf/showcase-wallpapers`。
- 自定义书脊会先保存在本机；如果 KOReader 已配置 WebDAV，可选择上传或下载对应书脊。
- WebDAV 账号信息由 KOReader 管理，插件不会在安装包中保存账号或密码。

## 数据与隐私

- 插件只读取本机书库、书籍侧载设置和 KOReader 阅读统计数据库。
- 除非用户主动使用自定义书脊的 WebDAV 功能，否则不会上传书籍、封面、笔记或统计数据。
- 卸载插件不会自动删除 `simplebookshelf.lua`、缩略图缓存、壁纸或 WebDAV 书脊文件。

## 卸载

1. 退出 KOReader。
2. 删除 `koreader/plugins/readingline.koplugin`。
3. 重新启动 KOReader。

如需同时清除设置，可再删除 KOReader 设置目录中的 `simplebookshelf.lua`；此操作会丢失插件配置，请先备份。

## 故障排查

- **菜单中没有插件**：确认目录名以 `.koplugin` 结尾，并确认没有多套嵌套目录。
- **出现两个 Reading Line**：删除旧的 `simplebookshelf.koplugin` 或其他重复副本。
- **统计为空**：启用 KOReader 自带“阅读统计”插件，并至少完成一次阅读记录写入。
- **跨设备时长不同**：确认双方同步顺序已经形成一次完整往返，并在同步前退出当前书籍。
- **封面首次出现较慢**：首次提取会生成缩略图缓存；后续进入页面会更快。
- **设置后未立即变化**：退出当前弹窗；必要时重新进入对应页面或重启 KOReader。

## 发布信息

- 版本：1.4.0
- 语言：简体中文界面
- 平台：KOReader

更新内容见 [CHANGELOG.md](CHANGELOG.md)。
