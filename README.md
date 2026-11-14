<div align="center">

# 比例守护 · Ratio Guardian

**按设定比例自动下载、控制带宽与磁盘占用的本地守护工具**

<a href="#-简体中文">简体中文</a> ·
<a href="#-繁體中文">繁體中文</a> ·
<a href="#-english">English</a> ·
<a href="#-日本語">日本語</a>

</div>

---

## 🇨🇳 简体中文

比例守护是一个跑在本机的下载守护工具：按你设定的**下载 / 上传比例**自动决定什么时候下、下多快，并始终守住磁盘占用上限。界面是本地网页，服务由 PowerShell 启动，**不需要额外安装运行时**。

### 环境要求

| 依赖 | 版本 |
|---|---|
| Windows | 10 / 11 |
| PowerShell | 5.1（系统自带即可） |
| 浏览器 | 任一现代浏览器 |

### 快速开始

1. 双击 `启动.bat` —— 后台启动 PowerShell 服务并打开本地页面
2. 在「目标下载比例」里填你想维持的比值，选工作模式
3. 在「数据源」里添加下载地址（内置若干镜像站模板，可直接勾选）
4. 观察「实时速率」和「下载任务」，需要时点「暂停」
5. 双击 `停止.bat` 退出

### 工作模式

| 模式 | 行为 |
|---|---|
| **智能** | 根据当前比例自动调节：低于目标就加速，达到目标就降速或暂停 |
| **全速** | 不受比例限制，跑满设定上限 |
| **手动** | 完全按你填的速度和并发执行 |

### 可调参数

- **目标下载比例**：核心指标，智能模式的判断依据
- **最大下载速度 / 手动模式速度**：单位与并发都在同一面板
- **并发任务**、**单块大小**：多线程分段下载的粒度
- **磁盘上限**：超过上限自动暂停并清理缓存
- **统计网卡**：多网卡机器可指定统计对象，默认「自动（推荐）」
- **本月已用（校准）**：手工填入运营商/站点统计的上行、下行，修正本地计数偏差

### 数据源

内置常见镜像站的 ISO 模板（如南大镜像、北外镜像的 Ubuntu 发行版），也可以 `+ 添加` 任意直链。列表保存在 `app/defaults/sources.json`，可自行编辑。

### 目录结构

```
启动.bat / 停止.bat      启停入口
app/launch.ps1           启动器（选端口、拉起服务）
app/server.ps1           本地 HTTP 服务
app/worker.ps1           下载工作进程
app/controller.ps1       任务调度
app/public/              浏览器界面
app/defaults/            默认数据源
downloads/               下载缓存（不纳入版本管理）
data/                    运行状态、日志、端口
```

> `downloads/` 与 `data/` 已在 `.gitignore` 中排除，不会进入仓库。

## 🇹🇼 繁體中文

比例守護是跑在本機的下載守護工具：依照你設定的**下載 / 上傳比例**自動決定何時下載、下載多快，並始終守住磁碟用量上限。介面是本機網頁，服務由 PowerShell 啟動，**不需額外安裝執行環境**。

### 環境需求

| 依賴 | 版本 |
|---|---|
| Windows | 10 / 11 |
| PowerShell | 5.1（系統內建即可） |
| 瀏覽器 | 任一現代瀏覽器 |

### 快速開始

1. 雙擊 `啟動.bat` —— 背景啟動 PowerShell 服務並開啟本機頁面
2. 在「目標下載比例」填入想維持的比值，選擇工作模式
3. 在「資料來源」新增下載網址（內建多個鏡像站範本，可直接勾選）
4. 觀察「即時速率」與「下載任務」，需要時按「暫停」
5. 雙擊 `停止.bat` 結束

### 工作模式

| 模式 | 行為 |
|---|---|
| **智慧** | 依目前比例自動調節：低於目標就加速，達到目標就降速或暫停 |
| **全速** | 不受比例限制，跑滿設定上限 |
| **手動** | 完全依照你填的速度與並行數執行 |

### 可調參數

- **目標下載比例**：核心指標，智慧模式的判斷依據
- **最大下載速度 / 手動模式速度**
- **並行任務**、**單塊大小**：多執行緒分段下載的粒度
- **磁碟上限**：超過上限自動暫停並清理快取
- **統計網卡**：多網卡機器可指定統計對象，預設「自動（推薦）」
- **本月已用（校正）**：手動填入業者／站點統計的上行、下行，修正本機計數偏差

### 資料來源

內建常見鏡像站的 ISO 範本（例如南大鏡像、北外鏡像的 Ubuntu 發行版），也可 `+ 新增` 任意直鏈。清單存於 `app/defaults/sources.json`，可自行編輯。

## 🇬🇧 English

Ratio Guardian is a local download daemon: it decides **when** and **how fast** to download based on the download/upload ratio you configure, while always respecting a disk cap. The UI is a local web page served by PowerShell — **no extra runtime to install**.

### Requirements

| Dependency | Version |
|---|---|
| Windows | 10 / 11 |
| PowerShell | 5.1 (built in) |
| Browser | any modern browser |

### Quick start

1. Double-click `启动.bat` — it starts the PowerShell service and opens the local page
2. Set **目标下载比例** (target ratio) and pick a working mode
3. Add sources under **数据源** (built-in mirror templates are included)
4. Watch **实时速率** and **下载任务**; press **暂停** (pause) when needed
5. Double-click `停止.bat` to stop

### Working modes

| Mode | Behaviour |
|---|---|
| **Smart** (智能) | Adjusts automatically: speeds up below the target ratio, slows down or pauses once reached |
| **Full speed** (全速) | Ignores the ratio, saturates your configured cap |
| **Manual** (手动) | Uses exactly the speed and concurrency you enter |

### Tunables

- **Target ratio** — the core metric used by Smart mode
- **Max download speed / manual speed**
- **Concurrent tasks**, **chunk size** — granularity of segmented downloads
- **Disk cap** — pauses and cleans the cache when exceeded
- **Network interface** — pick which NIC to count, defaults to `Auto (recommended)`
- **Used this month (calibration)** — enter the up/down totals reported by your ISP or tracker to correct local counters

### Sources

Built-in ISO templates for common mirrors (e.g. Ubuntu releases from Nanjing University and BFSU mirrors); you can also add any direct URL with `+ 添加`. The list lives in `app/defaults/sources.json` and can be edited by hand.

### Layout

```
启动.bat / 停止.bat      start / stop entry points
app/launch.ps1           launcher (port selection, service startup)
app/server.ps1           local HTTP service
app/worker.ps1           download worker
app/controller.ps1       task scheduling
app/public/              browser UI
app/defaults/            default sources
downloads/               download cache (git-ignored)
data/                    runtime state, logs, port (git-ignored)
```

## 🇯🇵 日本語

Ratio Guardian はローカルで動くダウンロード管理ツールです。設定した**ダウンロード / アップロード比**に基づいて「いつ・どの速度で」ダウンロードするかを自動で決め、ディスク使用量の上限も守ります。UI はローカルの Web ページ、サービスは PowerShell が起動するので**追加のランタイムは不要**です。

### 必要なもの

| 依存 | バージョン |
|---|---|
| Windows | 10 / 11 |
| PowerShell | 5.1（標準搭載） |
| ブラウザ | モダンブラウザ |

### クイックスタート

1. `启动.bat` をダブルクリック（PowerShell サービスが起動しページが開きます）
2. 「目标下载比例」に維持したい比率を入力し、動作モードを選択
3. 「数据源」にダウンロード URL を追加（ミラーサイトのテンプレートが内蔵されています）
4. 「实时速率」「下载任务」を確認、必要なら「暂停」
5. `停止.bat` で終了

### 動作モード

| モード | 動作 |
|---|---|
| **スマート** | 比率が目標未満なら加速、到達したら減速・停止 |
| **フルスピード** | 比率を無視して設定上限まで使用 |
| **手動** | 入力した速度と並列数に厳密に従う |

### 主な設定項目

- **目標ダウンロード比率** — スマートモードの判断基準
- **最大速度 / 手動モード速度**
- **同時タスク数**、**チャンクサイズ**
- **ディスク上限** — 超過時に自動停止しキャッシュを削除
- **統計 NIC** — 複数 NIC 環境では対象を指定（既定は「自動」）
- **今月の使用量（校正）** — 回線事業者やトラッカーの数値を入力して補正

### ディレクトリ構成

```
启动.bat / 停止.bat      起動・停止
app/launch.ps1           ランチャー（ポート選択・サービス起動）
app/server.ps1           ローカル HTTP サービス
app/worker.ps1           ダウンロードワーカー
app/controller.ps1       タスクスケジューラ
app/public/              ブラウザ UI
app/defaults/            既定のデータソース
downloads/               キャッシュ（git 管理外）
data/                    実行状態・ログ・ポート（git 管理外）
```
