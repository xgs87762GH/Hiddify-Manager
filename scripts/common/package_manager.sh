#!/bin/bash
# 定位本脚本所在目录；非 develop 环境（正式安装）固定使用 /opt 下的路径。
SCRIPT_DIR="$(realpath $(dirname "$BASH_SOURCE"))"
if [[ "$SCRIPT_DIR" != *develop* ]]; then
    SCRIPT_DIR="/opt/hiddify-manager/scripts/common"
fi

source $SCRIPT_DIR/utils.sh
# 随代码发布的包清单（版本/哈希），跟着代码走。
PACKAGES_LOCK="$SCRIPT_DIR/packages.lock"
# 当前已安装版本的记录属于运行期状态，必须能挺过解压 release 覆盖 scripts/，
# 因此放在 data/ 下。
CURRENT_PACKAGES="$HIDDIFY_DATA/packages.db"
mkdir -p "$HIDDIFY_DATA"
# 旧版本的 packages.db 曾放在 scripts/common 下，这里做一次性迁移。
if [ ! -f "$CURRENT_PACKAGES" ] && [ -f "$SCRIPT_DIR/packages.db" ]; then
    mv "$SCRIPT_DIR/packages.db" "$CURRENT_PACKAGES"
fi
touch "$CURRENT_PACKAGES"

# 计算文件 sha256
generate_hash() {
    local file=$1
    sha256sum "$file" | awk '{print $1}'
}

# 向 packages.lock 添加一条记录（不存在则追加，存在则更新）
add_package() {
    local package_name=$1
    local version=$2
    local arch=$3
    # 统一架构命名；"both" 表示两种架构各写一条。
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        both) 
            add_package "$package_name" "$version" "amd64" "$4"
            add_package "$package_name" "$version" "arm64" "$4"; 
            return ;;
    esac

    local url=$4

    if [[ -z "$package_name" || -z "$version" || -z "$arch" || -z "$url" ]]; then
        error "用法：$0 add <name> <version> <arch> <url>"
        exit 1
    fi

    # 先下载到临时文件，用于计算哈希
    temp_file="/tmp/${package_name}_${version}_${arch}.tmp"
    wget -q "$url" -O "$temp_file"
    if [[ $? -ne 0 ]]; then
        error "下载文件失败：$url"
        return 1
    fi

    local hash=$(generate_hash "$temp_file")
    rm "$temp_file"

    # 该版本是否已存在。用 awk 按字段精确比较：grep/sed 会把版本号里的 "."
    # 当正则通配（1.0.0 会命中 1x0y0），用 | 作 sed 分隔符时模式里的 | 还要写成 \|，
    # 语义很容易看错。
    existing_entry=$(awk -F'|' -v n="$package_name" -v v="$version" -v a="$arch" \
        '$1==n && $2==v && $3==a' "$PACKAGES_LOCK" || true)
    if [[ -n "$existing_entry" ]]; then
        # 更新已有记录（按字段改写，同样避免正则元字符问题）。
        # 失败必须中止：否则 mv 没执行也会打印"已更新"，留下假的成功记录。
        if awk -F'|' -v OFS='|' -v n="$package_name" -v v="$version" -v a="$arch" -v u="$url" -v h="$hash" \
            '$1==n && $2==v && $3==a {$4=u; $5=h} {print}' "$PACKAGES_LOCK" >"$PACKAGES_LOCK.tmp"; then
            mv "$PACKAGES_LOCK.tmp" "$PACKAGES_LOCK" ||
                { rm -f "$PACKAGES_LOCK.tmp"; error "无法写入 $PACKAGES_LOCK"; return 1; }
        else
            rm -f "$PACKAGES_LOCK.tmp"
            error "无法读取 $PACKAGES_LOCK"
            return 1
        fi
        echo "已更新软件包 $package_name $version（$arch）的记录。"
    else
        # 追加新记录
        echo "$package_name|$version|$arch|$url|$hash" >> "$PACKAGES_LOCK"
        echo "已添加软件包 $package_name $version（$arch）。"
    fi
}

# 下载软件包
# 参数：1=包名 2=输出文件名 3=版本（留空表示取最新） 4="force" 可强制重下
#       5=可选，安装产物路径（如解压后的二进制），用于判断"是否已安装"
download_package() {
    # 使用 ${n:-}：在 set -u 下，未传的第 3/4/5 参不能直接读 $n。
    local package_name="${1:-}"
    local output_file="${2:-}"
    local requested_version="${3:-}"

    if [[ -z "$package_name" || -z "$output_file" ]]; then
        error "用法：$0 download <name> <output_file> [<version>|force]"
        exit 10
    fi

    # "force" 可以出现在第 3 或第 4 个参数位置。
    local force=0
    if [[ "${3:-}" == "force" ]]; then
        force=1
        requested_version=""
    elif [[ "${4:-}" == "force" ]]; then
        force=1
    fi

    # 可选的第 5 个参数：最终安装产物（例如解压出来的二进制）。
    # 指定后，"是否已安装"改为检查该文件，而不是下载的压缩包——
    # 因为多个服务在解压后会删掉压缩包，用压缩包判断会导致每次重下。
    local marker="${5:-$output_file}"

    # 识别架构
    local arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)
            error "不支持的架构：$arch"
            return 1
            ;;
    esac

    # 当前已安装的版本（运行期记录）。
    local existing_version
    existing_version=$(awk -F'|' -v n="$package_name" '$1==n {print $2; exit}' "$CURRENT_PACKAGES")

    # 未指定版本时，取 lock 中最新的版本（|| true：取不到时留空，由下面的分支报错）。
    if [[ -z "$requested_version" ]]; then
        requested_version=$(get_latest_version "$package_name" "$arch" || true)
    fi

    # 在 lock 中查找对应条目（未命中属正常分支，下面会给出明确报错）。
    local entry
    entry=$(awk -F'|' -v n="$package_name" -v v="$requested_version" -v a="$arch" \
        '$1==n && $2==v && $3==a' "$PACKAGES_LOCK" | head -n 1 || true)
    if [[ -z "$entry" ]]; then
        error "未找到软件包 $package_name 版本 $requested_version（架构 $arch）。"
        return 2
    fi

    # 解析条目：包名|版本|架构|地址|哈希
    local name version url stored_hash
    IFS='|' read -r name version arch url stored_hash <<< "$entry"

    # 已记录为安装过：只有在产物确实存在时才跳过。
    # 传了第 5 个参数（marker）的调用方检查该二进制，因为压缩包装完就被删了，
    # 否则每次运行都会重新下载。未传 marker 的调用方保持原行为：
    # 下载的文件必须存在且哈希匹配。
    if [[ $force == 0 && "$requested_version" == "$existing_version" ]]; then
        if [[ "$marker" != "$output_file" ]]; then
            # marker 指向解压出的二进制：要求可执行，与调用方的
            # is_installed（command -v）/ -x 判断保持一致。
            # 若文件存在但丢了 +x 仍判为跳过，随后的解压就会失败。
            if [[ -x "$marker" ]]; then
                echo "软件包 $package_name $requested_version（$arch）已安装，跳过下载。"
                return 1
            fi
        elif [[ -f "$output_file" ]]; then
            local current_hash
            current_hash=$(generate_hash "$output_file")
            if [[ "$current_hash" == "$stored_hash" ]]; then
                echo "软件包 $package_name $requested_version（$arch）已下载且校验通过，跳过。"
                return 1
            fi
        fi
    fi

    # 开始下载
    echo "正在下载软件包 $package_name 版本 $requested_version（架构 $arch）……当前已装版本：${existing_version:-无}"
    local tmp_file=$(mktemp)
    curl -sL -o "$tmp_file" "$url"
    if [[ $? -ne 0 ]]; then
        error "下载文件失败：$url"
        rm -f "$tmp_file"
        return 3
    fi
    mv "$tmp_file" "$output_file"

    # 校验哈希
    local downloaded_hash=$(generate_hash "$output_file")
    if [[ "$downloaded_hash" != "$stored_hash" ]]; then
        error "文件 $output_file 哈希不匹配：期望 $stored_hash，实际 $downloaded_hash。"
        rm -f "$output_file"
        return 4
    fi

    echo "软件包 $package_name $version 已下载并校验完成：$output_file"
}
# 取 lock 中指定包/架构的最新版本号
get_latest_version() {
        # ${n:-}：set_installed_version 只传包名，set -u 下不能直接读 $2
        local package_name="${1:-}"
        local arch="${2:-}"
        local entry
        # || true：没有匹配条目时返回空版本而不是让调用方在 set -e 下中断
        if [[ -n "$arch" ]]; then
            entry=$(awk -F'|' -v n="$package_name" -v a="$arch" '$1==n && $3==a' "$PACKAGES_LOCK" | sort -t'|' -k2.1V | tail -n 1 || true)
        else
            entry=$(awk -F'|' -v n="$package_name" '$1==n' "$PACKAGES_LOCK" | sort -t'|' -k2.1V | tail -n 1 || true)
        fi
        local version
        version=${entry#*$package_name|} # 去掉包名部分
        version=${version%%|*} # 去掉其后的字段
        echo "$version"
}
# 记录某个包当前已安装的版本
set_installed_version() {
    local package_name=$1
    local version=$2
    # 未指定版本时取 lock 中最新的版本
    if [[ -z "$version" ]]; then
        version=$(get_latest_version $package_name)
    fi
    if [[ -z "$package_name" || -z "$version"  ]]; then
        error "用法：$0 set-installed <name> <version>"
        exit 1
    fi

    # 记录中是否已有该包（|| true：首次记录时 grep 必然未命中，不应让调用方 set -e 中断）
    existing_entry=$(awk -F'|' -v n="$package_name" '$1==n' "$CURRENT_PACKAGES" || true)
    if [[ -n "$existing_entry" ]]; then
        # 更新已有记录（按字段改写，避免包名里的正则元字符）
        if awk -F'|' -v OFS='|' -v n="$package_name" -v v="$version" '$1==n {$2=v} {print}' "$CURRENT_PACKAGES" >"$CURRENT_PACKAGES.tmp"; then
            mv "$CURRENT_PACKAGES.tmp" "$CURRENT_PACKAGES" ||
                { rm -f "$CURRENT_PACKAGES.tmp"; error "无法写入 $CURRENT_PACKAGES"; return 1; }
        else
            rm -f "$CURRENT_PACKAGES.tmp"
            error "无法读取 $CURRENT_PACKAGES"
            return 1
        fi
        echo "已将 $package_name 的已安装版本更新为 $version。"
    else
        # 追加新记录
        echo "$package_name|$version" >> "$CURRENT_PACKAGES"
        echo "已记录 $package_name 的安装版本为 $version。"
    fi
}

if [[ $BASH_SOURCE == "$0" ]]; then
# 命令行入口
case "$1" in
    add)
        add_package "$2" "$3" "$4" "$5"
        ;;
    download)
        download_package "$2" "$3" "$4"
        ;;
    set-installed)
        set_installed_version "$2" "$3"
        ;;
    get-latest-version)
        get_latest_version "$2" "$3"
        ;;
    *)
        error "用法：$0 {add|download|set-installed} <args>"
        exit 1
        ;;
esac
fi