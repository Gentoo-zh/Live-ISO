#!/bin/bash

WORKDIR="$(dirname "$(realpath "$0")")"

source "${WORKDIR}"/config

function cleanmount () {
    umount -l "${WORKDIR}/squashfs/var/tmp/portage" || true
    umount -l "${WORKDIR}/squashfs/mnt/gen-iso" || true
    exit
}

# wget 统一加超时/重试/续传，-nv 保留错误进日志（-q 会吞掉网络错误）
WGET="wget -nv --timeout=30 --tries=3 -c"

function fetchstage3 () {
    ${WGET} "${DIST}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" -O "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" || exit 1
    STAGE3PATH="$(sed -n '6p' "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" | cut -f 1 -d ' ')"
    echo "STAGE3PATH:" "${STAGE3PATH}"
    # 守卫:latest txt 下载/解析失败会得到空串,空串会让 wget 去抓目录索引写坏文件
    [ -n "${STAGE3PATH}" ] || { echo "解析 stage3 路径失败"; exit 1; }
    STAGE3="$(basename "${STAGE3PATH}")"

    if ( ! grep 'stage3downloadok' "${WORKDIR}/stat" );then
        rm -rf "squashfs/${STAGE3}"
        ${WGET} "${DIST}/${STAGE3PATH}" -O "squashfs/${STAGE3}" || exit 1
        # 校验 sha256:官方每个 stage3 同目录有 .sha256(PGP 包裹),取其中
        # 64 位十六进制那行喂给 sha256sum -c,不过即终止,杜绝坏/被篡改的 stage3
        ${WGET} "${DIST}/${STAGE3PATH}.sha256" -O "squashfs/${STAGE3}.sha256" || exit 1
        ( cd squashfs && grep -E "^[0-9a-f]{64}.*$(basename "${STAGE3}")" "${STAGE3}.sha256" | sha256sum -c - ) \
            || { echo "stage3 sha256 校验失败"; exit 1; }
        rm -f "squashfs/${STAGE3}.sha256"
        echo 'stage3downloadok' >> "${WORKDIR}/stat"
    fi
}

function unpackstage3 () {
    # unpack stage3
    pushd "${WORKDIR}/squashfs" || exit 1
    if ( ! grep 'unpackok' "${WORKDIR}/stat" );then
        tar xpf "${STAGE3}" --xattrs-include='*.*' --numeric-owner \
            && echo 'unpackok' >> "${WORKDIR}/stat" \
	        && rm "${STAGE3}" || exit 1
    fi
popd || exit 1
}

function buildarchscript () {
    # check arch-chroot tools
    if [ ! -f "${WORKDIR}/arch-scripts/arch-chroot.in" ];then
        git submodule update --init --recursive || exit 1
    fi
    if [ ! -x "${WORKDIR}/arch-scripts/arch-chroot" ];then
        pushd "${WORKDIR}/arch-scripts" || exit 1
        make || exit 1
        popd || exit 1
    fi
}

function crun () {
	"${WORKDIR}"/arch-scripts/arch-chroot "${WORKDIR}/squashfs" bash -c "$*"
}

function syncrepo () {
# try three times to sync
if [ -d "${WORKDIR}/squashfs/var/db/repos/gentoo" ];then
    for n in {1..3};do
	if (crun which git);then
            if (crun emerge --sync);then
                break;
            fi
        else
            pushd "${WORKDIR}/squashfs/var/db/repos/gentoo" || exit 1
            if (git pull);then
                popd || exit 1
                break;
            else
                popd || exit 1
            fi
        fi
        if [ "${n}" == "3" ];then
            exit 1
        fi
    done
else
    for n in {1..3};do
        if (git clone --depth=1 "${GITMIRROR}" "${WORKDIR}/squashfs/var/db/repos/gentoo");then
            break;
        fi
        if [ "${n}" == "3" ];then
            exit 1
        fi
    done
fi
}

function refreshconfig() {
    # refresh MAKEOPTS
    sed -i "s/MAKEOPTS=\".*\"/MAKEOPTS=\""${MAKEOPTS}"\"/g" "${WORKDIR}/squashfs/etc/portage/make.conf/common"

    # refresh MIRROR
    echo "GENTOO_MIRRORS=\""${MIRROR}"/gentoo\"" > "${WORKDIR}/squashfs/etc/portage/make.conf/mirror"
}

function mounttmpfs () {
    if [[ -n "${TMPFS}" ]];then
        # init notmpfs dir
        crun mkdir -p /var/tmp/{notmpfs,portage}
        crun chown portage:portage /var/tmp/{notmpfs,portage}
        crun chmod 775 /var/tmp/{notmpfs,portage}
        # mount tmpfs
        if ( ! findmnt "${WORKDIR}/squashfs/var/tmp/portage" ) && [ -n "${TMPFS}" ];then
            crun mount -t tmpfs -o size="${TMPFS}",uid=portage,gid=portage,mode=775 tmpfs /var/tmp/portage
        elif ( findmnt "${WORKDIR}/squashfs/var/tmp/portage" ) && [ -n "${TMPFS}" ];then
            crun mount -o remount,size="${TMPFS}" /var/tmp/portage
        fi
    fi
}

function makesquashfs (){
    mkdir -p "${WORKDIR}/iso/LiveOS"
    rm -f "${WORKDIR}/iso/LiveOS/squashfs.img"
    # squashfs 用 zstd 而非 xz:zstd 解压快得多,live 从 U 盘边读边解压更流畅;
    # -Xcompression-level 19 压缩率仍接近 xz。(squashfs-tools 已开 zstd USE)。块大小 1M。
    mksquashfs "${WORKDIR}/squashfs/" "${WORKDIR}/iso/LiveOS/squashfs.img" \
    -wildcards -ef exclude.txt -b 1024K -comp zstd -Xcompression-level 19 -progress -processors "${CORES}" || exit 1
}

function buildbootfiles () {
    # make initramfs with live support
    KVER="$(ls "${WORKDIR}/squashfs/lib/modules" | sort -Vr | head -n1)"
    # -i /lib/keymaps:把键盘布局打进 initramfs(官方 livegui 同款),非美式键盘 live 早期也能输入
    # --xz:与官方 livegui 一致的 initramfs 压缩,体积更小
    #
    # nvidia 闭源驱动【不进 initramfs】(不走 early KMS):闭源 grub 项传 gigos.gpu=nvidia,
    # 开机后由 gigos-nvidia-load.service 常规 modprobe nvidia 四件套 + 建设备节点(此时 udev 已就绪、
    # /dev/nvidia* 正常创建)。这是 Arch/Gentoo wiki 推荐的常规做法,比 early KMS 简单可靠、
    # 不踩 initramfs 漏建节点(nvidia-smi 连不上、KWin 退软渲)那一串坑。
    crun dracut --no-hostonly -f --kver "${KVER}" --xz --add dmsquash-live --add dmsquash-live-autooverlay --add crypt -i /lib/keymaps /lib/keymaps || exit 1

    # copy the kernel to iso workdir
    mkdir -p "${WORKDIR}/iso/boot"
    cp -v "${WORKDIR}/squashfs/boot/kernel-${KVER}" "${WORKDIR}/iso/boot/kernel" || exit 1
    cp -v "${WORKDIR}/squashfs/boot/initramfs-${KVER}.img" "${WORKDIR}/iso/boot/initrd" || exit 1
}

function buildiso () {
    # bind iso dir to rootfs to make iso
    if ( ! findmnt "${WORKDIR}/squashfs/mnt/gen-iso" );then
        mkdir -p "${WORKDIR}/squashfs/mnt/gen-iso"
        mount --bind "${WORKDIR}" "${WORKDIR}/squashfs/mnt/gen-iso"
    fi
    crun grub-mkrescue -o /mnt/gen-iso/gig-os-"$(date +%Y%m%d)".iso /mnt/gen-iso/iso -- -as mkisofs -V 'Gig-OS' || exit 1
}

# ctrl+c anytime to stop
trap cleanmount INT
trap cleanmount EXIT

# must run as root
if (( EUID != 0 ));then
    echo 'This script must be run with root privileges'
    exit 1
fi

# Download the stage3
mkdir -p "${WORKDIR}/squashfs"

fetchstage3

unpackstage3

buildarchscript

# copy extra staff to squashfs but package.use
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/" --exclude etc/portage/package.use/ --exclude etc/portage/make.conf/use || exit 1

refreshconfig
mounttmpfs

# DNS
cp --dereference /etc/resolv.conf "${WORKDIR}/squashfs"/etc/

syncrepo

# upgrade portage first
crun emerge -vu1q --jobs "${CORES}" portage
# we need git to sync overlay
if ( ! crun which git);then
    crun emerge -vuDq --jobs "${CORES}" dev-vcs/git || exit 1
fi
syncrepo

# sync full extra staff
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/" || exit 1

refreshconfig

# [gigos] @world 前(最后一次 syncrepo 之后)把 calamares-settings-gig 的 9999 ebuild(git-r3)
# 指向【我们的 Gentoo-zh fork】(含:装机后清自动登录/语言服务/桌面安装按钮、按 live 选择配
# nvidia、shellprocess 启用)。若在 syncrepo 前改会被 emerge --sync/git pull 重置回 Gig-OS 上游
# (其 shellprocess 注释掉=清理全不生效);放此处之后无 sync,@world 的 git-r3 即用本 URL。
CSGEB="${WORKDIR}/squashfs/var/db/repos/gig/app-admin/calamares-settings-gig/calamares-settings-gig-9999.ebuild"
if [ -f "${CSGEB}" ];then
    sed -i "s#https://github.com/Gig-OS/calamares-settings-gig.git#https://github.com/Gentoo-zh/calamares-settings-gig.git#" "${CSGEB}"
    echo "[gigos] calamares-settings-gig ebuild → Gentoo-zh fork(@world 前最终生效)"
else
    echo "[gigos] 致命:未找到 calamares-settings-gig 9999 ebuild → 无法指向带清理的 fork;中止构建"
    echo "        (否则会出无装机清理的盘:装好的系统残留 autologin / SSH 密码登录等 live 后门)"
    exit 1
fi

# upgrade system
crun emerge -uvDNq --jobs "${CORES}" --keep-going @world || exit 1
crun emerge --jobs "${CORES}" @live-rebuild || exit 1
crun emerge -c || exit 1
crun eclean-kernel --no-bootloader-update --no-mount -n 1 || exit 1
crun eclean-pkg || true

# run hooks in squashfs
for hook in "${WORKDIR}"/hooks/*;do
    source "${hook}" || exit 1
done

makesquashfs

buildbootfiles

# copy extra staff for iso
# include-iso 含 boot/grub/grub.cfg(整个 GRUB 启动菜单),注入失败会让
# grub-mkrescue 打包出不可启动 ISO,故必须 || exit 1 而非 || true
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-iso/* "${WORKDIR}/iso" || exit 1

buildiso

cleanmount
