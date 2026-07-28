# DeepClean

[English](README.md) | 中文文档

DeepClean 是一款强大而智能的 macOS 系统清理及开发者工具管理软件。它能帮助您安全地清理缓存、日志和卸载残留，释放宝贵的磁盘空间，同时提供对已安装的开发环境及全局包的深度透视功能。

<img width="832" height="715" alt="Image" src="https://github.com/user-attachments/assets/963cfb51-f571-4223-bb3c-33fe8f35ae72" />

## 功能特性

### 🧹 智能系统清理
DeepClean 能够对占据磁盘空间的无用文件进行分类并安全清理：
- **系统废纸篓与日志:** 清空废纸篓并清理系统日志。
- **应用缓存:** 清理 `~/Library/Caches` 以释放空间。
- **应用保存状态:** 移除应用的 Saved Application State。
- **已卸载应用残留:** 智能检测并移除 `~/Library/Application Support` 中已经被卸载的应用残留文件。
- **用户目录残留:** 发现并清理主目录下过时的隐藏配置文件和无用数据。

### 🛠 Xcode & iOS 开发者专属清理
专门为 iOS 和 macOS 开发者打造，用于管理 Xcode 庞大的磁盘占用：
- **Xcode DerivedData & Archives:** 快速清理 DerivedData 和打包的 Archives。
- **iOS 模拟器缓存:** 清理核心模拟器缓存。
- **按版本分类的模拟器设备:** 查看并管理按 iOS 版本分类的模拟器大小。
- **失效模拟器 (Unavailable Simulators):** 自动检测并移除系统已不再支持或失效的模拟器。

### 📦 开发者工具透视 (只读)
完整掌握您的开发环境及全局依赖包的大小和位置：
- **Homebrew:** 追踪已安装的 Formulae 和 Casks。
- **Node.js:** 全面扫描 Node.js 安装情况，支持所有主流版本管理器（`nvm`、`fnm`、`volta`、`asdf`、`nodenv`、`n`、Homebrew、`/usr/local` 及环境变量 PATH），精准定位全局包。
- **全局包管理器:** 查看以下工具的全局包及占用空间：
  - `npm`, `pnpm`, `Yarn`
  - `Cargo` (Rust)
  - `Ruby Gems`
  - `Go`
  - `Pipx` (Python)
- **开发工具缓存:** 追踪主目录下各种开发工具产生的缓存数据。

### 🔍 高级搜索与导航
- **实时搜索:** 瞬间过滤出你想要的缓存、工具或残留项。
- **在 Finder 中显示:** 一键在 Finder 中定位并打开具体的缓存目录或应用程序，方便手动检查。
- **可视化存储指示器:** 直观的磁盘使用情况进度条，一目了然地查看已用和可用空间。

## 安装与运行
当前处于开发阶段。请克隆仓库后使用 Xcode 编译并运行。

## 开源协议
MIT
