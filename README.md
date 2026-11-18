# 洛洛 · 桌面陪伴脚本

Deepseek Harness写的喵

给自己来个提前99天的成人礼嘻嘻~~

给 [MateEngine](https://store.steampowered.com/app/2647760/MateEngine/) 里的 VRM 角色接上一个「会说人话」的灵魂：
定时主动开口、可以打字聊天、有长期记忆、有情绪、能记闹钟。

纯 PowerShell + C#（WPF/WinForms 在运行时编译），不需要装 Python、不需要打包成 exe。

> ⚠️ 这个仓库只放**脚本本体**。人设、记忆、日志、API key 一律不包含，需要自己准备（见下文）。

---

## 它是什么

| 文件                                                          | 作用                       |
| ----------------------------------------------------------- | ------------------------ |
| `luoluo-proactive.ps1`                                      | 主程序：主动说话、聊天窗口、记忆、闹钟、调度循环 |
| `LuoluoPanel3.cs` + `luoluo-panel.ps1` + `launch-panel.vbs` | 桌面小面板（启动/暂停/闹钟/叫她）       |
| `watchdog.ps1`                                              | 看门狗：调度器挂了自动拉起            |
| `subtitle-watch.ps1`                                        | 可选：读 B 站窗口字幕，让她知道你在看什么   |
| `im-watch.ps1`                                              | 可选：读 QQ 聊天区，让她知道你刚在跟谁聊   |
| `data-sample/`                                              | 示例数据文件，复制到 `data/` 改成自己的 |

---

## 依赖

1. **Windows 10/11** + **PowerShell 5.1**（系统自带）
2. **MateEngine**（Steam），并且把它的 LLM 接口配好——脚本读的是 MateEngine 自己的配置：
   - `%USERPROFILE%\AppData\LocalLow\Shinymoon\MateEngineX\LLMProxySettings.json`（里面有 apiKey / endpoint / model）
3. 一个人设文件 `ZomeAI_prompt.txt`（同目录，你自己写）

> 也就是说：**脚本不存 API key**，它借用 MateEngine 已经配好的那一份。

---

## 安装

1. 把整个文件夹放到任意位置，例如 `D:\MateTools\luoluo`
2. 新建 `data` 目录，把 `data-sample` 里的示例文件复制进去并改名：
   - `facts.example.txt` → `data\facts.txt`（她会一直记住的事）
   - `memes.example.txt` → `data\memes.txt`（可选，梗库，格式 `梗|解释`）
   - `myphrases.example.txt` → `data\myphrases.txt`（可选，你想让她学的口头禅）
3. 复制 `config.example.json` 为 `config.json`，按需填：

```json
{
  "mateEngineData": "",
  "yejinPrompt": ""
}
```

- `mateEngineData`：留空就用默认位置；放在别处才需要填
- `yejinPrompt`：第二个人格（可选，不用就留空）
4. 双击 `launch-panel.vbs` 开面板；或直接跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\luoluo-proactive.ps1
```

> 首次运行会自己生成 `data\memory.json` 等文件。

---

## 常用命令

```powershell
.\luoluo-proactive.ps1 -OpenChat        # 打开聊天窗口
.\luoluo-proactive.ps1 -Once            # 让她立刻说一句
.\luoluo-proactive.ps1 -DryRun          # 只生成、不弹窗（调人设用）
.\luoluo-proactive.ps1 -Say "一句话"     # 直接让她显示这句话
.\luoluo-proactive.ps1 -SayAs "…"       # 把这句当成「你说的话」发进对话
.\luoluo-proactive.ps1 -Notes           # 看她的长期记忆
.\luoluo-proactive.ps1 -AddNote "…"     # 手动加一条
.\luoluo-proactive.ps1 -Alarms          # 看闹钟
.\luoluo-proactive.ps1 -AddAlarm 21:30 -AlarmText "吃药" -Daily
.\luoluo-proactive.ps1 -Usage           # 今天花了多少
.\luoluo-proactive.ps1 -Stop            # 停掉所有进程
```

---

## 她怎么记住你

| 文件                   | 是什么                 | 会不会自动变        |
| -------------------- | ------------------- | ------------- |
| `data\facts.txt`     | 你写的固定事实，**每次都进提示词** | 不会（你手改）       |
| `data\memory.json`   | 自动总结的 8 条长期记忆       | 会（最多 40 分钟一次） |
| `data\chat`          | 最近 10 句对话           | 会             |
| `data\myphrases.txt` | 你想让她学的口头禅           | 不会            |
| `data\memes.txt`     | 梗库，22% 概率用一个        | 不会            |

**记不住某件事** → 写进 `facts.txt`，最稳。

---

## 隐私

- 所有数据都在 `data\` 里，**不上传任何地方**；
- 只有拼好的提示词会发给 API（DeepSeek 或你自己配的接口）；
- `git push` 之前请确认 `data\` 已被忽略（仓库自带 `.gitignore`）。

---

## 已知限制

- 只支持 Windows；WPF 界面在 PowerShell 里运行时编译，**中文文件必须存 UTF-8 with BOM**，否则会乱码；
- 聊天窗口是置顶透明窗，截图类功能（字幕/QQ）会被它挡住；
- 主动说话的频率、静默时段在脚本顶部的 `param` 里改；
- 人设写得好不好，直接决定她像不像人——**这部分不提供**。

---

## 许可

脚本部分随便用、随便改；人设与故事（不在本仓库）版权归原作者，不随仓库分发。

玩的开心喵~~
