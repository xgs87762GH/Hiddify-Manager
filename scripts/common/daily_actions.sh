#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# 切到脚本自身所在目录，保证相对路径可用
cd $( dirname -- "$0"; )


# systemctl restart systemd-journald
# sysctl -w vm.drop_caches=3
