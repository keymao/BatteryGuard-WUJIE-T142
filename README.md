# 无界电池管家 BatteryGuard

**MECHREVO 无界 14X（T142-HPT-R 平台）硬件级电池限充守护** —— 不依赖厂商支持，直接经 SMBus 控制充电芯片实现充电上限保护。

## 这是什么

机械革命无界系列官方未提供任何充电阈值设置（BIOS/控制中心/ACPI 均无）。本项目通过 EC 逆向找到了完整的硬件控制链路，实现：

- **充电上限保护**（默认 80% 停充 / 75% 恢复，可调）
- 插电状态下电池长期稳定维持在设定区间（等效联想/华硕"养护模式"）
- 满充久插、低电量提醒，容量/循环 CSV 日志
- 看门狗：守护进程死亡自动恢复充电并重启
- 熔断保护：EC 与 Windows 电池状态矛盾时立即停止一切硬件访问
- 深色皮肤 GUI（单文件 EXE，内嵌驱动，自绘电池仪表盘，托盘常驻）

## 原理（一句话版）

充电芯片挂在与 EC 共享的 SMBus 总线上（从机地址 0x09，SBS 规范）。向其寄存器 0x14（ChargingCurrent）写 0 即停充；恢复时按电池（0x0B）的充电请求写回。总线访问使用 EC RAM 中未启用的 **SMBus master E**（经 I2EC 端口 0x4E/0x4F 间接访问 16 位 EC RAM），交易前后完整保存/恢复控制器配置，与固件 master A 互不干扰（含仲裁/NACK/超时重试）。

完整逆向证据链（ACPI 反汇编、寄存器映射、协议细节、安全边界）未随本仓库发布；核心协议实现见 `src/Hw.cs` 与 `BatteryGuard.ps1` 内联硬件层源码。

方案移植自 [xcdd/BatteryGuard-for-WUJIE-T142-STX](https://github.com/xcdd/BatteryGuard-for-WUJIE-T142-STX)（无界 14X Pro 同准系统姐妹型号），并在本机（T142-HPT-R + BIOS T142_HPTR_V12）逐项实测验证：充电芯片（0x4F32/0x000A）与电池（AEC4168126-4S1P）与参考机完全同款。

## 文件结构

```
BatteryGuard.ps1        守护进程脚本版（PowerShell 5.1，含完整硬件层 C# 内联）
BatteryGuardGui.ps1     GUI 脚本版（WinForms）
ec-snapshot.ps1         EC 只读快照 / 四状态对比工具（研究用，纯只读）
src/                    EXE 版 C# 源码（与脚本版同源协议）
  Program.cs            入口/模式分发/UAC 自提升
  Hw.cs                 硬件层：I2EC + SMBus master E 交易（核心）
  Daemon.cs             守护主循环 + 看门狗 + 电源请求防睡眠/唤醒接管
  State.cs              配置/runtime 状态持久化
  Installer.cs          开机自启任务管理（schtasks）
  Ui.cs                 深色皮肤 GUI（DPI 感知 + 屏幕自适应）
app.ico                 应用图标（自绘电池充电样式，多尺寸）
make_icon.ps1           图标生成脚本（GDI+ 绘制）
build.ps1               一键编译脚本（csc .NET Framework 4）
```

## 构建单文件 EXE

依赖唯一第三方文件 `inpoutx64.dll`（不入库，需自取）：

1. 从 [RyzenAdj v0.19.0](https://github.com/FlyGoat/RyzenAdj/releases/tag/v0.19.0) 官方发行包获取 `inpoutx64.dll`
2. 校验 SHA-256：`5F27ED4D5CD58A1EE23DEEB802E09E73F3A1D884CE2135F6E827F67B171269E7`
3. 放到仓库根的 `driver\inpoutx64.dll`（build.ps1 会把它作为资源嵌入 EXE）
4. 管理员 PowerShell 运行 `.\build.ps1`（参数见脚本内注释）

EXE 首次运行时自动释放内嵌 DLL 并加载 InpOut 内核驱动服务。

## 使用

```
BatteryGuard.exe                # GUI（自动 UAC，最小化到托盘）
BatteryGuard.exe -daemon        # 守护进程（计划任务用）
BatteryGuard.exe -watchdog      # 看门狗（每 10 分钟计划任务用）
BatteryGuard.exe -install       # 安装登录自启（守护+看门狗）
BatteryGuard.exe -uninstall     # 卸载（先恢复充电再清任务）
BatteryGuard.exe -resume        # 命令行应急恢复充电
```

GUI：实时电量/充电芯片寄存器/心跳、区间调节、立即停充/恢复、暂停保护、守护启停。

## 安全边界

- **适用机型硬校验**：充电芯片 ID + 电池签名 + 主板型号不符时拒绝启动（防误用于其他设备）
- 写后回读、64mA 值域检查、SMBus 配置完整恢复
- 虚假 Critical 熔断、心跳看门狗、卸载/退出先恢复充电
- **已知边界**：关机/重启后至守护自启前的窗口期充电不受限（关机插电会充满）；**守护插电运行期间会通过电源请求阻止系统"超时自动睡眠"以防止充电失控，但手动点"睡眠"/合盖/关机仍不受限（会持续充到满电），唤醒后守护会立即重新停充并弹通知说明**——进程冻结期间无法对抗 EC 固件的充电电流重写，此为物理边界；直接控制充电硬件理论上可能影响原厂保修

## ⚠ 免责声明

本项目逆向厂商未公开的硬件接口并直接控制充电芯片，**使用风险自担**：可能导致失去原厂保修、极端情况下电池行为异常。仅建议在已验证的同款硬件（WUJIE Series-T142-HPT-R / 同款充电芯片 0x4F32 + 电池 AEC4168126-4S1P）上使用。

## 致谢

- [xcdd/BatteryGuard-for-WUJIE-T142-STX](https://github.com/xcdd/BatteryGuard-for-WUJIE-T142-STX) —— SMBus master E 独立通道方案与安全设计（MIT）
- [Highrez InpOut](https://www.highrez.co.uk/downloads/inpout32/default.htm) —— 端口 I/O 内核驱动
- [FlyGoat/RyzenAdj](https://github.com/FlyGoat/RyzenAdj) —— InpOut DLL 来源（v0.19.0 官方发行包）

## License

原创代码 MIT。`inpoutx64.dll` 遵循 Highrez InpOut 原许可。
