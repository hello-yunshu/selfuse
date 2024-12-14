#!/bin/bash
board=$(cat /tmp/sysinfo/board_name | cut -d , -f2)
DISK="/dev/sda"
PART="/dev/sda2"
fdisk -l ${DISK} >>/dev/null 2>&1 || (echo "找不到磁盘: $DISK - 请测试磁盘名称！" >>/etc/panyi_${board} && exit 1)
MAXSIZEMB=$(printf %s\\n 'unit MB print list' | parted | grep "Disk ${DISK}" | cut -d' ' -f3 | tr -d MB)
    echo "[ok] ${PART} 将会扩展到 ${MAXSIZEMB} MB " >>/etc/panyi_${board}
    parted ${DISK} resizepart 2 ${MAXSIZEMB}
    [ $? != 0 ] && echo "扩展分区出错了！" >>/etc/panyi_${board}
    e2fsck -y ${PART}
    resize2fs ${PART}
    [ $? = 0 ] && echo "文件系统扩展成功" >>/etc/panyi_${board}
