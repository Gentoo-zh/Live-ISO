#!/bin/bash

# NetworkManager
crun systemctl enable NetworkManager

# Sddm
crun systemctl enable sddm

# Live 开机语言切换(读 gigos.lang= 内核参数,在 sddm 前设 locale/Plasma 语言)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-live-lang.sh"
crun systemctl enable gigos-live-lang.service

# CPU_FLAGS_X86 按本机 CPU 自动生成(live 与装好的系统每次启动按真机 CPU 覆盖 make.conf/cpuflags)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-cpuflags.sh"
crun systemctl enable gigos-cpuflags.service

# nvidia 常规加载(闭源 nvidia 启动项传 gigos.gpu=nvidia:开机后 modprobe nvidia 四件套 + 建节点,
# 非 early KMS;由服务的 ConditionKernelCommandLine 守卫,开源/AMD/Intel 项不命中)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-nvidia-load.sh"
crun systemctl enable gigos-nvidia-load.service

# 桌面「安装系统」按钮设可执行(KDE Folder View 双击直接起 Calamares;skel→各用户 ~/Desktop)
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/calamares.desktop"

# 桌面「启动 SSH」两个按钮(允许密码登录 / 仅密钥)+ 其前后端脚本设可执行(live 调试用)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-ssh.sh" "${WORKDIR}/squashfs/usr/local/bin/gigos-ssh-button.sh"
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-ssh-password.desktop" "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-ssh-keyonly.desktop"
