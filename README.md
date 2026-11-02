# DSH 完成提示音（ding-chime）

[![License: MIT](https://img.shields.io/badge/License-MIT-fbbf24.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows-0078D6)
![DSH](https://img.shields.io/badge/DSH-plugin-4D6BFE)

给 [DSH](https://github.com/deepseek-ai)（DeepSeek Harness）桌面版做的**任务完成提醒**插件：

> 每轮对话结束 → 响一声柔和的提示音 + 任务栏按钮闪一下；想安静就点托盘铃铛静音，还能在 10 种音色里挑。

灵感来自 Codex 的「干完活响一声」，但这个实现是**系统级**的：声音在宿主机上播放，
窗口最小化、切到别的应用、页面在后台都照响。

---

## 功能

| 能力 | 说明 |
| --- | --- |
| 完成提醒 | 会话从「运行中」回到「空闲」时响一次；一整轮只响一次，中间的多次工具调用不会连响 |
| 任务栏闪烁 | 用 Win32 `FlashWindowEx` 让 DSH 的任务栏按钮闪，切回窗口即停（窗口最小化也看得见） |
| 音量自适应 | 先读 Windows 主音量，再按比例缩放波形，让实际听到的响度大致恒定：系统音量 100% 时它自己小声放，30% 时自动放大一点 |
| 托盘控制 | 通知区域一个铃铛：左键静音/恢复，右键选音色、试听 |
| 静音即静默 | 静音状态下既不响也不闪 |
| 子任务不打扰 | subagent 结束不响，避免一个任务里叮个没完 |
| 永不刺耳 | 峰值默认只到 -0.5 dBFS 再按增益缩放；合成音色刻意做了低通 + 缓起音 |

## 环境要求

- **Windows 10 / 11**
- DSH 桌面版（插件跑在 Host 进程里，通过 `powershell.exe` 出声、WinForms 出托盘）
- 生成系统音效时需要 `ffmpeg`（可选，只影响 `win-*` 音色）

## 安装

1. 把整个目录放到任意位置（例如 `%USERPROFILE%\dsh-plugins\ding-chime`）。
2. 用 DSH 的插件管理能力安装这个本地 bundle 目录：在 DSH 里让 agent 执行
   `plugin_manager` 的 `install_bundle`，目标指向该目录的绝对路径。
   （安装后它会以 `link:` 形式进入当前 profile，重启 DSH 依然有效。）
3. 装好后托盘会出现一个琥珀色铃铛。

> 升级插件代码后再执行一次「移除 → 安装」，或重启 DSH，才会加载新模块。

## 配置

插件行在 `cordis.patch.yml`，可选项：

```yaml
- insert:
    - id: ding-chime
      name: '@local/ding-chime'
      config:
        enabled: true          # false = 整个插件不挂载
        volume: 22             # 目标峰值响度 1..100（22 已经很轻）
        adaptiveVolume: true   # false = 不跟随系统音量，直接按 volume 播
        subagents: false       # true = 子任务结束也响
        preview: false         # true = 插件启动时先响一声
        tray: true             # false = 不显示托盘图标
        sound: bell            # 默认音色；托盘里选过之后以 state.json 为准
```

- 觉得还响：`volume` 调到 12~15；觉得太轻：30~35。
- 托盘里的选择写进 `%LOCALAPPDATA%\dsh-ding-chime\state.json`，优先级高于配置。

## 音色

托盘右键 → **音效** → 点一个立刻切换并试听。

| 分类 | id | 名字 |
| --- | --- | --- |
| 本机生成 | `win-generic` / `win-calendar` / `win-email` / `win-message` / `win-ding` / `win-chime` / `win-nudge` | Windows 系统通知 / 日历 / 邮件 / 消息 / 经典 Ding / 风铃 / 轻推 |
| 随仓库分发 | `bell` / `deep` / `tech` | 木质铃 / 低音钟 / 电子 |

### 那 7 个「系统音效」怎么来的

它们是把 `C:\Windows\Media\*.wav` 重新处理（去首尾静音、转单声道 44.1 kHz、峰值归一）得到的：

```powershell
powershell -ExecutionPolicy Bypass -File tools/import-sources.ps1
```

脚本会把结果写进 `assets/sounds/win-*.wav`。

> ⚠️ **这些文件不在仓库里**，也不应该提交：它们是微软的系统素材，只允许在你自己这台机器上使用。
> 仓库的 `.gitignore` 已经排除了它们；没有它们时插件会自动回落到随仓库分发的 `bell`。

### 自定义声音（DIY）

除了内置音色，还能用**自己的声音**：

**① 让它说话** —— 托盘右键 →「朗读文字…」，输入一句话（默认「任务完成了」），
用 Windows 自带语音合成生成 WAV，立刻设为提示音并试听。
（这台机器上用的是 `Microsoft Huihui Desktop`（zh-CN）；没有中文语音时退回默认语音。）

**② 换成自己的音频** —— 托盘右键 →「打开自定义音效文件夹」，把 PCM WAV 丢进去，
再在「音效」菜单最下面的**自定义**分组里选中它。

- 只认 **WAV**（`System.Media.SoundPlayer` 的限制）。别的格式先转：
  `ffmpeg -i in.mp3 -ac 1 -ar 44100 -c:a pcm_s16le out.wav`
- 文件放在 `%LOCALAPPDATA%\dsh-ding-chime\sounds\`，菜单列出最近 12 个，按修改时间倒序。
- 选中的自定义音效在 `state.json` 里是**绝对路径**（不是 id），移动文件后会自动回落到内置音色。

### 自己加内置音色

- 合成：改 `tools/make-chime.py` 里的 `VOICES` 表（频率、泛音、衰减、低通、回声、时长），
  运行 `python tools/make-chime.py`。
- 换源：把任意 WAV/MP3/OGG 丢进 `tools/import-sources.ps1` 的映射表再跑一遍，
  然后在 `index.js` 的 `SOUND_IDS` 和 `tray.ps1` 的 `$voices` 里登记 id。

> 还没生成的本机音效会在托盘菜单里显示为「（未生成）」并且点不了；万一 `state.json` 里选了
> 一个不存在的音色，响铃时会自动回落到当前可用的音色，不会变成没声音。

## 工作原理

```
DSH Host 进程
├── index.js        监听 agent/status、agent/turn-stopping → 决定何时响；拉起托盘；提供本机静音路由
│   ├── play.ps1    读主音量 → 算增益 → 缩放 PCM → SoundPlayer 播放（每次响铃一个短命进程）
│   │   └── DshChime.cs   CoreAudio 读主音量 + WAV 缩放（Add-Type 在内存里编译）
│   └── tray.ps1    WinForms NotifyIcon：状态图标、静音菜单、音效菜单、任务栏闪烁
└── state.json / events.json / *.log   与托盘共享的状态与诊断（%LOCALAPPDATA%\dsh-ding-chime）
```

- **为什么声音走 Host 而不是浏览器**：浏览器音频依赖页面焦点和自动播放策略，窗口一关就没了；
  Host 侧用 `System.Media.SoundPlayer`，最小化也在响。
- **为什么用文件交换状态**：托盘和 Host 是两个进程，`state.json` 当唯一真源，双方各写各的、
  读方每次重读，省掉一层 IPC。

## 排错

| 现象 | 先看 |
| --- | --- |
| 没声音 | `%LOCALAPPDATA%\dsh-ding-chime\play.log`：有没有 `spawn error`、`exit code`、`out="gain=…"` |
| 托盘没出现 | 任务栏右下角 `^` 溢出区；`tray.log` 里有没有 `notify visible` |
| 任务栏不闪 | `tray.log` 里的 `flash result=`，`1` 表示已找到窗口并成功调用 |
| 改代码没生效 | 插件模块有缓存：先 `remove_bundle` 再 `install_bundle`，或重启 DSH |

一个容易踩的坑：**不要用 `detached: true` 起这种短命子进程**——本宿主会在约 120 ms 内把它回收
（退出码 0、无输出），表现为「执行了但没声音」。本项目用前台 `spawn`。

## 目录结构

```
index.js            Host 半：事件监听、调度、托盘拉起、本机静音路由
tray.ps1            通知区域图标 + 任务栏闪烁
play.ps1            音量自适应播放
DshChime.cs         CoreAudio + PCM 缩放（play.ps1 内联编译）
cordis.patch.yml    插件行与默认配置
package.json        bundle 清单（dsh.bundle.patch）
icon.svg            插件页图标
locale/*.json       插件页标题与描述（中/英）
assets/sounds/      bell / deep / tech（+ 本地生成的 win-*）
assets/tray-*.png   托盘三态图标
tools/              音效合成、系统音效导入、托盘图标生成
```

## 授权

代码以 **MIT** 分发，见 [LICENSE](LICENSE)。
随仓库的合成音效（`bell` / `deep` / `tech`）为原创，同许可证。
`win-*` 音效由使用者在本机自行生成，不随仓库分发。
