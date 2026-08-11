# LittleClean

[English](README.md) | 中文文档

LittleClean 是一款强大而智能的 macOS 系统清理及开发者工具管理软件。它能帮助您轻松彻底地卸载应用程序、安全地清理缓存与日志，并移除残留文件以释放宝贵的磁盘空间，同时提供对已安装的开发环境及全局包的深度透视功能。
<img width="336" alt="Image" src="https://github.com/user-attachments/assets/4eb9d387-71de-4ddc-bf1e-fbeb42739c92" />
<img width="336" alt="Image" src="https://github.com/user-attachments/assets/29ff0c9b-5e2d-4d20-95d8-216b209e93a7" />
<img width="336" alt="Image" src="https://github.com/user-attachments/assets/d57b6f01-12bd-476a-aee9-b41b514e1796" />

## 安装与运行

您可以从 [Releases](https://github.com/leibnizli/LittleClean/releases) 页面下载最新编译好的版本。（最低支持 macOS 14）

或者，您也可以克隆仓库后使用 Xcode 编译并运行。

## 功能特性

### 应用卸载 (Uninstall Apps)
轻松且彻底地移除不需要的应用程序，同时自动清理其关联的缓存、偏好设置、容器、Launch Agents 及其他残留文件。项目会移入废纸篓，必要时可恢复。卸载前会退出正在运行的目标应用。列表会标注 Homebrew Cask 与 Setapp 应用。LittleClean 自身及受保护的系统应用不可卸载。

也可以在 Finder 中直接卸载，无需打开 LittleClean 主窗口：
1. 先运行一次 LittleClean，以便系统注册服务。
2. 在 Finder 中选中一个或多个 `.app`。
3. 右键菜单选择 **服务 → 使用 LittleClean 卸载**（或通过 Finder 的 **服务** 菜单）。
4. 在确认对话框中查看将移入废纸篓的应用包及关联项目；可取消勾选不需要删除的残留项，应用包本身不可取消。
5. 确认后开始卸载。成功时不再额外弹窗，失败时仍会提示错误。

### 安全清理 (Safe Cleanup)
LittleClean 能够对占据磁盘空间的无用文件进行分类并安全清理。勾选后点击 **Clean**，或通过右键菜单单独清理某一项：
- **系统废纸篓与日志:** 清空废纸篓并清理系统日志。
- **应用缓存:** 清理 `~/Library/Caches` 以释放空间。
- **应用保存状态:** 移除应用的 Saved Application State。
- **已卸载应用残留:** 智能检测并移除 `~/Library/Application Support` 中已经被卸载的应用残留文件。
- **容器残留:** 检测并移除 `~/Library/Containers` 下已无主的应用容器。
- **Xcode 清理:** 清理 DerivedData、iOS 模拟器缓存，并自动移除失效模拟器。
- **用户目录工具缓存:** 清理主目录下已知开发工具缓存（如 npm、pnpm、Yarn、Bun、Deno、Gradle、Maven、Cargo 等），保留对应文件夹本身。

### 深度分析 (Deep Analysis)
只读模式，完整掌握开发环境与磁盘占用情况。此模式下不可删除任何内容：
- **Xcode Archives 与模拟器:** 查看 Xcode Archives，以及按 runtime 版本分组的模拟器设备占用。
- **Homebrew:** 追踪已安装的 Formulae 和 Casks。
- **Node.js:** 全面扫描 Node.js 安装情况，支持所有主流版本管理器（`nvm`、`fnm`、`volta`、`asdf`、`nodenv`、`n`、Homebrew、`/usr/local` 及环境变量 PATH），精准定位全局包。
- **全局包管理器:** 查看 `npm`、`pnpm`、`Yarn`、`Cargo`（Rust）、Ruby Gems、Go、Pipx 的全局包及占用空间。
- **其他 PATH 工具:** 列出 PATH 中其余非系统二进制工具。
- **用户目录概览:** 枚举 `~` 下的非系统项，并为已知工具与配置（Docker、Rust、Android、编辑器、云 CLI 等）提供说明。

### 搜索、导航与更多
- **实时搜索:** 瞬间过滤出你想要的缓存、工具或残留项。
- **表格排序:** 可按路径或大小排序，默认按占用从大到小。
- **在 Finder 中显示:** 一键在 Finder 中定位并打开具体的缓存目录或应用程序，方便手动检查。
- **可视化存储指示器:** 直观的磁盘使用情况饼图，一目了然地查看已用和可用空间。
- **完全磁盘访问权限:** 检测是否缺少完全磁盘访问权限，必要时可打开系统设置以完成更深扫描与清理。
- **更新检查:** 发现 GitHub 上有新版本时会提示。
- **双语界面:** 支持英文与简体中文。

## 开源协议
MIT
