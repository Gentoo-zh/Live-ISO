#!/bin/sh
# 按本机 CPU 自适应生成 CPU_FLAGS_X86 写入 make.conf。
# 出厂 cpuflags 是带标记的安全基线(x86-64-v3);本服务在 live 与装好系统的每次启动
# 按真实 CPU 重算覆盖。一旦用户删掉标记行(表示已自定义),即停止覆盖,尊重用户。
set -u
F=/etc/portage/make.conf/cpuflags
MARK='# gigos-auto-cpuflags'

# 文件存在且【没有】自动标记 = 用户已手改 → 不动它
if [ -e "$F" ] && ! grep -q "$MARK" "$F"; then
    exit 0
fi

command -v cpuid2cpuflags >/dev/null 2>&1 || exit 0
FLAGS=$(cpuid2cpuflags 2>/dev/null | sed 's/^CPU_FLAGS_X86: *//')
[ -n "$FLAGS" ] || exit 0

{
    echo "$MARK"
    echo "# 由 gigos-cpuflags 按本机 CPU 自动生成;删除上面这行标记即停止自动覆盖,可改成自己的值。"
    printf 'CPU_FLAGS_X86="%s"\n' "$FLAGS"
} > "$F"
