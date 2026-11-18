<p align="center"><img src="docs/icon.png" width="112" alt="AI Runs 图标"></p>

<h1 align="center">AI Runs</h1>

<p align="center">
给同时开很多个 Claude Code、Codex 会话的人用的 macOS 菜单栏小工具。<br>
一眼看到哪些在等你、其余的在干嘛，点一下就回到那个会话。
</p>

<p align="center"><a href="README.md">English</a></p>

<p align="center"><img src="docs/panel.png" width="446" alt="AI Runs 面板（示例数据）"></p>

三个 App 里同时跑着五个 agent 的时候，很难分清哪个做完了、哪个在等你回答、哪个其实已经停了。AI Runs 把它们放进菜单栏里的同一个列表：

- **Needs you（等你）**：等你批准、等你回答的会话，并显示已经等了多久。
- **Working（在跑）**：每个会话此刻在做什么，比如"正在编译"、"正在改 routes.ts"、"第 3/7 步"。
- **Done（做完）**：已经完成的会话，放在最下面，不打扰你。

所有数据只在你的 Mac 上。不用注册账号，没有服务器，不往外发任何东西。

> **这是给朋友试用的早期版本。**会有不完善的地方，遇到问题请一定告诉我，见下面的[反馈](#反馈)。

## 安装

需要 Apple 芯片（M1 及以后）的 Mac，macOS 14 或更新版本。

1. 从[最新发布页](https://github.com/alextang809/ai-runs/releases/latest)下载 **AI-Runs.zip** 并解压。
2. 把 **AI Runs** 拖进「应用程序」文件夹。
3. 打开它。因为还没有经过苹果公证，第一次打开会被 macOS 拦下：
   - 打开「系统设置 → 隐私与安全性」，往下找到"已阻止 AI Runs…"，点 **仍要打开**，再确认一次；
   - 或者在终端里运行一次：
     `xattr -dr com.apple.quarantine "/Applications/AI Runs.app"`

Intel 芯片的 Mac 请[从源码构建](#从源码构建)。

## 设置（2 分钟）

第一次打开时，AI Runs 会自动弹出设置窗口。

1. **Claude Code：点 Install。**这会在 `~/.claude/settings.json` 里加上 AI Runs。终端里、VS Code 里、Claude 桌面版里的 Claude Code 都能被识别。
2. **Codex：点 Install，然后打开 Codex。**它会弹出 **Review hooks**，里面有 4 个 AI Runs 的 hook，点 **Allow all**。不点的话，Codex 什么都不会发过来。
3. 新开或继续任意一个会话，一秒内就会出现在菜单栏里。

之后 macOS 可能会各问一次下面几个权限：

| 什么时候 | 权限 | 用途 |
|---|---|---|
| 第一次点终端（Terminal 或 iTerm2）里的会话 | 自动化 | 把对应的标签页切到前面 |
| 第一次点 Claude 桌面版里的会话 | 辅助功能 | 在 Claude 侧边栏里选中那个线程 |
| 第一次有会话等你 | 通知 | 有会话等你批准或回答时弹出横幅（在设置里选哪些情况要通知） |

## 菜单栏里找不到图标？

图标是三根小竖条：<img src="docs/icon.png" width="14">。如果看不到：

- **按 ⌥⌘A**，在任何地方都能打开面板。
- **带刘海的 MacBook：**刘海旁边放不下的图标会被 macOS 自动藏起来。可以去掉几个别的图标，或者在 Bartender / Ice 里把 AI Runs 放进始终显示区，靠近时钟的位置。
- 也可以在设置里打开 **Also show AI Runs in the Dock**，让它同时出现在程序坞里。

## 怎么用

**每一行**会显示：会话所在 App 的真实图标；会话名字（和 Claude、Codex 侧边栏里的一样）；状态；在哪里跑；正在做什么；还有一条最近一小时的小时间线。

| 你看到的 | 意思 |
|---|---|
| **APPROVE**（实心） | 它想执行命令或改文件，在等你批准 |
| **NEEDS INPUT**（实心） | 它问了你问题，或者说自己卡住了 |
| **REPLIED**（浅色） | 它结束了这一轮，但 AI Runs 判断不出它是否需要你 |
| **WORKING**（描边） | 它在跑，下面一行写着它在做什么 |
| **SCHEDULED / BACKGROUND**（灰色） | 它在等自己定的唤醒任务或后台任务，会自己接着跑 |
| **DONE ✓**（灰色） | 你交代的事它做完了 |

颜色只用来区分工具：**Claude** 是它的陶土橙，**Codex** 是黑色（深色模式下是白色），其他都是灰色。

"做完了"还是"需要你输入"，按可靠程度从高到低这样判断：
1. Claude 调用了专门向你提问的工具；
2. 它的步骤清单全部完成；
3. 它最后一段话的措辞（中英文都认）；
4. macOS 26 上交给苹果的本机模型判断。

判断不出来就显示 **REPLIED**，不瞎猜。鼠标停在某一行上，能看到它是怎么判断的。

**点一下某一行**，就回到那个会话：

| 会话在哪里跑 | 点一下会 |
|---|---|
| Terminal 或 iTerm2 | 切到它的标签页；标签页关了，就在同一个文件夹里新开一个标签页接着跑 |
| VS Code、Cursor | 打开那个项目的窗口 |
| Codex 桌面版 | 直接打开那个线程 |
| Claude 桌面版 | 把 Claude 带到前台，并在侧边栏里选中那个线程 |

**其他功能**

- **移除会话：**鼠标移上去点 **×**，或者右键 → Remove from List。之后几秒内可以点 **Undo**（⌘Z）撤销。移除后，只有你在那个会话里再发消息，它才会回来。
- **改名、置顶到钉板**等：右键某一行，或者把鼠标停在上面看详情。
- **悬浮窗：**菜单里点 **Show Floating Window**。一个小胶囊会停在所有 App、所有桌面、全屏窗口的上面，显示有几个会话在等你。点一下展开，能看到会话列表和钉板；可以拖到任何地方，靠近屏幕边缘会自动吸附。在设置里可以让它在有会话等你时自动展开。
- **钉板：**在悬浮窗的 Pinned 标签里，按项目分组，记下不想丢的线程和随手的笔记。往里拖文字或链接就会生成卡片。
- **通知：**有会话等你批准或回答时弹出横幅，可以直接点 Open 跳过去，或点 Snooze 稍后提醒。在设置里选择哪些情况要通知。
- **Pin Front AI Window：**把你刚才在用的浏览器标签页或 App 钉住。claude.ai、chatgpt.com 上的网页对话暂时没法自动跟踪，可以用这个功能。

## 隐私

AI Runs 只读写你 Mac 上的文件：

- 它会在 `~/.claude/settings.json` 和 `~/.codex/hooks.json` 里**添加 hook**。只动命令里含有 `airuns-hook` 的条目，每个文件第一次改动前会备份成 `*.airuns-backup`。每个 hook 只是往 `~/.airuns/events.jsonl` 里追加一行记录。
- 它会从 Claude 桌面版的会话列表、Codex 的 `~/.codex/state_5.sqlite` 里**读取线程名字**（只读）。
- 在 macOS 26 上，它可能会用**苹果的本机模型**给会话起名、判断回复，模型在你的 Mac 上运行。

它不会发起任何网络请求。

## 反馈

哪里看不懂、不对、缺了什么，都请告诉我。最有用的是：

- 面板的截图（隐私内容可以打码）；
- 你本来以为会怎样，实际又发生了什么；
- 你的 macOS 版本，以及你用的是 Claude Code、Codex，还是两个都用。

可以在 GitHub 上[提 issue](https://github.com/alextang809/ai-runs/issues)，也可以直接发消息给我。

## 卸载

1. 打开 AI Runs 的设置，分别在 Claude Code 和 Codex 那一行点 **Remove**。
2. 退出 AI Runs，把它从「应用程序」拖到废纸篓。
3. 删除它的数据：`rm -rf ~/.airuns`

## 已知限制

- 网页上的会话（claude.ai、chatgpt.com、云端 agent）还没法自动跟踪，可以用 Pin Front AI Window 钉住。
- Ghostty、Warp 等终端不支持脚本控制，点一下只能把那个 App 带到前台，选不中具体的标签页。
- 现在的版本是临时签名，每次更新后 macOS 可能会要你重新打开一次辅助功能权限。
- 还不能显示各个工具的剩余用量。

## 从源码构建

需要 macOS 14 或更新版本，以及 Xcode 16（或 Swift 6 工具链）。

```sh
git clone https://github.com/alextang809/ai-runs.git
cd ai-runs
./Scripts/package_app.sh
open "build/AI Runs.app"
```

用 `swift test` 运行测试。

## 许可证

MIT
