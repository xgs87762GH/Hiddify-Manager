#!/bin/sh

# 设置该变量后，安装脚本会额外生成一条 Easysetup（一键安装）链接。
export CREATE_EASYSETUP_LINK="true"
bash -c "$(curl -Lfo- https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/common/download_install.sh)"