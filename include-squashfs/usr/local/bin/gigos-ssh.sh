#!/bin/bash
# 桌面「启动 SSH」按钮的 root 后端（经 pkexec 调用）。用法: gigos-ssh.sh password|keyonly
# 背景:live 默认不开 sshd;且 /etc/ssh/sshd_config.d/9999999gentoo.conf 设 PasswordAuthentication no
# （仅密钥）。本脚本按需开启 sshd,密码登录用一个排在它【之前】的 drop-in 覆盖(sshd 首个匹配生效)。
set -e
DROP=/etc/ssh/sshd_config.d/00-gigos-passwordlogin.conf
case "${1:-}" in
  password)
    printf '# gigos 桌面按钮开启的密码登录(live 调试用;文件名 00 排在 9999999gentoo.conf 之前)\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' > "$DROP"
    ;;
  keyonly)
    rm -f "$DROP"
    ;;
  *)
    echo "用法: $0 password|keyonly" >&2; exit 2
    ;;
esac
ssh-keygen -A >/dev/null 2>&1 || true          # 首次无主机密钥则生成
systemctl enable --now sshd >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || systemctl start sshd
exit 0
