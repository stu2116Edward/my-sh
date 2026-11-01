#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root权限运行" 1>&2
   exit 1
fi

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
ORANGE='\033[38;5;208m'
NC='\033[0m' # 关闭颜色输出。

# 读取确认输入，回车时按“是”处理。
confirm() {
    while true; do
        read -p "$1 [Y/n]: " response
        case "$response" in
            [yY][eE][sS]|[yY]|"")
                return 0
                ;;
            [nN][oO]|[nN])
                return 1
                ;;
            *)
                echo -e "${RED}无效输入，请输入 Y 或 N。${NC}"
                ;;
        esac
    done
}

# 读取危险操作的确认输入，回车时按“否”处理。
confirm_default_no() {
    while true; do
        read -p "$1 [y/N]: " response
        case "$response" in
            [yY][eE][sS]|[yY])
                return 0
                ;;
            [nN][oO]|[nN]|"")
                return 1
                ;;
            *)
                echo -e "${RED}无效输入，请输入 Y 或 N。${NC}"
                ;;
        esac
    done
}

# 等待用户按键后返回上级菜单。
pause_before_return() {
    echo
    read -n 1 -s -r -p "按任意键返回主菜单..." key
    echo
}

# 将系统架构名称转换为 Docker 发布包使用的架构名称。
get_system_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        armv7l|armhf)
            echo "armhf"
            ;;
        armv6l)
            echo "armel"
            ;;
        s390x)
            echo "s390x"
            ;;
        ppc64le)
            echo "ppc64le"
            ;;
        *)
            echo -e "${RED}不支持的架构: $arch${NC}" >&2
            return 1
            ;;
    esac
}

# 定义Docker镜像源列表
DOCKER_MIRRORS=(
    "https://mirrors.aliyun.com/docker-ce/linux/static/stable"
    "https://mirrors.tencent.com/docker-ce/linux/static/stable"
    "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable"
    "https://mirrors.ustc.edu.cn/docker-ce/linux/static/stable"
    "https://download.docker.com/linux/static/stable"
    "https://mirrors.pku.edu.cn/docker-ce/linux/static/stable"
)

DOCKER_STATIC_DIR="/usr/local/lib/docker-tools/static"
DOCKER_STATIC_CLI="/usr/local/bin/docker"
# 保留 /usr/bin/docker 入口，兼容已缓存该命令路径的 Shell。
DOCKER_STATIC_COMPAT_CLI="/usr/bin/docker"
DOCKER_LEGACY_RUNTIME_MARKER="/var/lib/docker-tools/legacy-static-runtime"

# 检查并修复标准 /dev/null 权限，不替换缺失或类型异常的设备。
ensure_dev_null() {
    if [ ! -c /dev/null ] || [ "$(stat -c '%t:%T' /dev/null 2>/dev/null)" != "1:3" ]; then
        echo -e "${RED}/dev/null 不是标准字符设备，无法安全运行 APT。请先修复系统的 /dev/null。${NC}"
        return 1
    fi

    if [ "$(stat -c '%a' /dev/null 2>/dev/null)" != "666" ]; then
        if ! chmod 666 /dev/null; then
            echo -e "${RED}无法修复 /dev/null 权限；请检查系统设备权限。${NC}"
            return 1
        fi
    fi

    if ! ( : > /dev/null ); then
        echo -e "${RED}/dev/null 不可写，APT 无法正常运行；请检查系统挂载和设备权限。${NC}"
        return 1
    fi
    return 0
}

# 检测当前系统使用的包管理器。
get_package_manager() {
    if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    elif command -v opkg >/dev/null 2>&1; then
        echo "opkg"
    elif [ "$(uname -s)" = "FreeBSD" ] && command -v pkg >/dev/null 2>&1; then
        echo "pkg"
    else
        return 1
    fi
}

# 更新当前包管理器的软件包索引或缓存。
package_manager_update() {
    local manager
    manager="$(get_package_manager)" || {
        echo -e "${RED}未检测到支持的包管理器。${NC}" >&2
        return 1
    }

    case "$manager" in
        apt) ensure_dev_null && apt-get update ;;
        dnf) dnf makecache ;;
        yum) yum makecache ;;
        apk) apk update ;;
        pacman) pacman -Sy ;;
        zypper) zypper --non-interactive refresh ;;
        opkg) opkg update ;;
        pkg) return 0 ;;
    esac
}

# 使用当前包管理器安装指定软件包。
package_manager_install() {
    local manager
    manager="$(get_package_manager)" || {
        echo -e "${RED}未检测到支持的包管理器。${NC}" >&2
        return 1
    }

    case "$manager" in
        apt) ensure_dev_null && apt-get install -y "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        apk) apk add "$@" ;;
        pacman) pacman -S --needed --noconfirm "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        opkg) opkg install "$@" ;;
        pkg) pkg install -y "$@" ;;
    esac
}

# 使用当前包管理器卸载指定软件包。
package_manager_remove() {
    local manager
    manager="$(get_package_manager)" || {
        echo -e "${RED}未检测到支持的包管理器。${NC}" >&2
        return 1
    }

    case "$manager" in
        apt) ensure_dev_null && apt-get remove -y "$@" ;;
        dnf) dnf remove -y "$@" ;;
        yum) yum remove -y "$@" ;;
        apk) apk del "$@" ;;
        pacman) pacman -R --noconfirm "$@" ;;
        zypper) zypper --non-interactive remove "$@" ;;
        opkg) opkg remove "$@" ;;
        pkg) pkg delete -y "$@" ;;
    esac
}

# 清除指定软件包及其包管理器支持的配置文件。
package_manager_purge() {
    local manager
    manager="$(get_package_manager)" || {
        echo -e "${RED}未检测到支持的包管理器。${NC}" >&2
        return 1
    }

    case "$manager" in
        apt) ensure_dev_null && apt-get purge -y "$@" ;;
        dnf) dnf remove -y "$@" ;;
        yum) yum remove -y "$@" ;;
        apk) apk del "$@" ;;
        pacman) pacman -R --noconfirm "$@" ;;
        zypper) zypper --non-interactive remove "$@" ;;
        opkg) opkg remove "$@" ;;
        pkg) pkg delete -y "$@" ;;
    esac
}

# 使用当前包管理器重新安装指定软件包。
package_manager_reinstall() {
    local manager
    manager="$(get_package_manager)" || {
        echo -e "${RED}未检测到支持的包管理器。${NC}" >&2
        return 1
    }

    case "$manager" in
        apt) ensure_dev_null && apt-get install --reinstall -y "$@" ;;
        dnf) dnf reinstall -y "$@" ;;
        yum) yum reinstall -y "$@" ;;
        apk) apk fix "$@" ;;
        pacman) pacman -S --noconfirm "$@" ;;
        zypper) zypper --non-interactive install --force "$@" ;;
        opkg) opkg install --force-reinstall "$@" ;;
        pkg) pkg install -f -y "$@" ;;
    esac
}

# 判断指定软件包是否已安装。
package_is_installed() {
    local package="$1"
    local manager
    manager="$(get_package_manager)" || return 1

    case "$manager" in
        apt) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' ;;
        dnf|yum) rpm -q "$package" >/dev/null 2>&1 ;;
        apk) apk info -e "$package" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$package" >/dev/null 2>&1 ;;
        zypper) rpm -q "$package" >/dev/null 2>&1 ;;
        opkg) opkg status "$package" 2>/dev/null | grep -q '^Status:.* installed' ;;
        pkg) pkg info -e "$package" >/dev/null 2>&1 ;;
    esac
}

# 列出指定软件包登记的文件路径。
list_package_files() {
    local package="$1"
    local manager
    manager="$(get_package_manager)" || return 1

    case "$manager" in
        apt) dpkg-query -L "$package" 2>/dev/null ;;
        dnf|yum|zypper) rpm -ql "$package" 2>/dev/null ;;
        apk) apk info -L "$package" 2>/dev/null ;;
        pacman) pacman -Qlq "$package" 2>/dev/null ;;
        opkg) opkg files "$package" 2>/dev/null ;;
        pkg) pkg query -l "$package" 2>/dev/null ;;
    esac
}

# 卸载软件包并反馈其移除的文件路径。
remove_package_with_report() {
    local package="$1"
    local path
    local existing_paths=()

    while IFS= read -r path; do
        case "$path" in
            /*)
                if [ -e "$path" ] || [ -L "$path" ]; then
                    existing_paths+=("$path")
                fi
                ;;
        esac
    done < <(list_package_files "$package")

    echo -e "${YELLOW}正在卸载软件包：$package${NC}"
    package_manager_purge "$package" || {
        echo -e "${RED}卸载软件包失败：$package${NC}"
        return 1
    }

    for path in "${existing_paths[@]}"; do
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            echo -e "${YELLOW}软件包已删除路径：$path${NC}"
        fi
    done
}

# 删除指定文件或目录，并反馈处理结果。
remove_path_with_report() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        echo -e "${YELLOW}正在删除路径：$path${NC}"
        if ! rm -rfv -- "$path"; then
            echo -e "${RED}删除路径失败：$path${NC}"
            return 1
        fi
        echo -e "${GREEN}已删除路径：$path${NC}"
    fi
}

# 卸载 Docker 网络命名空间挂载点，避免清理运行目录时遇到忙碌挂载。
unmount_docker_netns_mounts() {
    local mountpoint
    local mount_targets=()

    [ -d /run/docker/netns ] || return 0

    if command -v findmnt >/dev/null 2>&1; then
        while IFS= read -r mountpoint; do
            case "$mountpoint" in
                /run/docker/netns|/run/docker/netns/*)
                    mount_targets+=("$mountpoint")
                    ;;
            esac
        done < <(findmnt -rn -o TARGET 2>/dev/null |
            awk '{ depth = gsub(/\//, "/"); print depth "\t" $0 }' |
            sort -rn | cut -f2-)
    elif [ -r /proc/self/mountinfo ]; then
        while IFS= read -r mountpoint; do
            mount_targets+=("$mountpoint")
        done < <(
            awk '
                $5 == "/run/docker/netns" || index($5, "/run/docker/netns/") == 1 {
                    target = $5
                    depth = gsub(/\//, "/", target)
                    print depth "\t" target
                }
            ' /proc/self/mountinfo | sort -rn | cut -f2-
        )
    else
        echo -e "${RED}无法检查 /run/docker/netns 的挂载点；为避免误删，取消目录清理。${NC}"
        return 1
    fi

    for mountpoint in "${mount_targets[@]}"; do
        echo -e "${YELLOW}正在卸载 Docker 网络命名空间挂载点：$mountpoint${NC}"
        if umount "$mountpoint"; then
            echo -e "${GREEN}已卸载挂载点：$mountpoint${NC}"
        elif umount -l "$mountpoint"; then
            echo -e "${YELLOW}挂载点仍被占用，已延迟卸载：$mountpoint${NC}"
        else
            echo -e "${RED}无法卸载 Docker 网络命名空间挂载点：$mountpoint${NC}"
            echo -e "${RED}请停止仍在使用该网络命名空间的进程后重试。${NC}"
            return 1
        fi
    done
}

# 停止并清理指定用户的 Docker 配置、无根模式数据及用户服务。
remove_user_docker_environment() {
    local user_name user_uid user_home path unit unit_state user_units_changed
    while IFS=: read -r user_name _ user_uid _ _ user_home _; do
        [ -n "$user_home" ] && [ "$user_home" != "/" ] || continue
        user_units_changed=0
        if systemd_is_running && command -v runuser >/dev/null 2>&1 &&
           [ -S "/run/user/$user_uid/bus" ]; then
            for unit in docker.socket docker.service; do
                if runuser -u "$user_name" -- env \
                    XDG_RUNTIME_DIR="/run/user/$user_uid" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" \
                    systemctl --user is-active --quiet "$unit"; then
                    if ! runuser -u "$user_name" -- env \
                        XDG_RUNTIME_DIR="/run/user/$user_uid" \
                        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" \
                        systemctl --user stop "$unit"; then
                        echo -e "${RED}停止用户服务失败：$user_name/$unit${NC}"
                        return 1
                    fi
                    echo -e "${GREEN}已停止用户服务：$user_name/$unit${NC}"
                    user_units_changed=1
                fi
                unit_state="$(runuser -u "$user_name" -- env \
                    XDG_RUNTIME_DIR="/run/user/$user_uid" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" \
                    systemctl --user is-enabled "$unit" 2>/dev/null || true)"
                case "$unit_state" in
                    enabled|enabled-runtime|linked|linked-runtime|alias)
                        if ! runuser -u "$user_name" -- env \
                            XDG_RUNTIME_DIR="/run/user/$user_uid" \
                            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" \
                            systemctl --user disable "$unit"; then
                            echo -e "${RED}禁用用户服务失败：$user_name/$unit${NC}"
                            return 1
                        fi
                        echo -e "${GREEN}已禁用用户服务：$user_name/$unit${NC}"
                        user_units_changed=1
                        ;;
                esac
            done
        fi
        local user_paths=(
            "${user_home%/}/.docker"
            "${user_home%/}/.config/docker"
            "${user_home%/}/.local/share/docker"
            "${user_home%/}/.config/systemd/user/docker.service"
            "${user_home%/}/.config/systemd/user/docker.socket"
            "${user_home%/}/.config/systemd/user/docker.service.d"
            "${user_home%/}/.config/systemd/user/default.target.wants/docker.service"
            "${user_home%/}/.config/systemd/user/sockets.target.wants/docker.socket"
        )
        for path in "${user_paths[@]}"; do
            remove_path_with_report "$path" || return 1
        done
        case "$user_uid" in
            ''|*[!0-9]*) ;;
            *) remove_path_with_report "/run/user/$user_uid/docker.sock" || return 1 ;;
        esac
        if [ "$user_units_changed" -eq 1 ] && ! runuser -u "$user_name" -- env \
            XDG_RUNTIME_DIR="/run/user/$user_uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" \
            systemctl --user daemon-reload; then
            echo -e "${RED}重新加载用户 systemd 配置失败：$user_name${NC}"
            return 1
        fi
    done
}

# 判断当前系统是否由 systemd 作为 PID 1 运行。
systemd_is_running() {
    command -v systemctl >/dev/null 2>&1 &&
        [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

# 解除 Docker systemd 单元的屏蔽状态。
unmask_docker_units() {
    local unit state
    for unit in docker.service docker.socket; do
        state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        case "$state" in
            masked|masked-runtime)
                systemctl unmask "$unit" || return 1
                ;;
        esac
    done
    return 0
}

# 查询维护指定路径的软件包名称。
get_package_owner() {
    local path="$1" owner=""
    if command -v dpkg-query >/dev/null 2>&1; then
        owner=$(dpkg-query -S "$path" 2>/dev/null | head -n1 | sed 's/: .*//')
    fi
    if [ -z "$owner" ] && command -v rpm >/dev/null 2>&1; then
        owner=$(rpm -qf "$path" 2>/dev/null)
    fi
    if [ -z "$owner" ] && command -v pacman >/dev/null 2>&1; then
        owner=$(pacman -Qoq "$path" 2>/dev/null)
    fi
    if [ -z "$owner" ] && command -v apk >/dev/null 2>&1; then
        owner=$(apk info --who-owns "$path" 2>/dev/null | sed -n 's/.* is owned by \([^ ]*\).*/\1/p')
    fi
    if [ -z "$owner" ] && command -v opkg >/dev/null 2>&1; then
        owner=$(opkg search "$path" 2>/dev/null | head -n1 | awk '{print $1}')
    fi
    if [ -z "$owner" ] && [ "$(uname -s)" = "FreeBSD" ] && command -v pkg >/dev/null 2>&1; then
        owner=$(pkg which -q "$path" 2>/dev/null)
    fi
    [ -n "$owner" ] && printf '%s\n' "$owner"
}

# 清理脚本管理的静态 Docker 文件及其服务定义。
cleanup_static_docker_files() {
    local path service_removed=0 legacy_static=0
    local report_removed=0 removed_path
    local static_paths=()
    [ "$1" = "report" ] && report_removed=1
    local docker_files=(/usr/bin/docker /usr/bin/dockerd /usr/local/bin/docker /usr/local/bin/dockerd)
    local runtime_files=(
        /usr/bin/containerd /usr/bin/containerd-shim /usr/bin/containerd-shim-runc-v1
        /usr/bin/containerd-shim-runc-v2 /usr/bin/ctr /usr/bin/runc
        /usr/local/bin/containerd /usr/local/bin/containerd-shim /usr/local/bin/containerd-shim-runc-v1
        /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/ctr /usr/local/bin/runc
    )
    [ -f "$DOCKER_LEGACY_RUNTIME_MARKER" ] && legacy_static=1

    if systemd_is_running; then
        systemctl stop docker.socket docker.service >/dev/null 2>&1 || true
        systemctl disable docker.service >/dev/null 2>&1 || true
    fi

    if [ -f /etc/systemd/system/docker.service ] &&
       grep -q '^ExecStart=/usr/bin/dockerd$' /etc/systemd/system/docker.service; then
        mkdir -p "$(dirname "$DOCKER_LEGACY_RUNTIME_MARKER")" || return 1
        touch "$DOCKER_LEGACY_RUNTIME_MARKER" || return 1
        legacy_static=1
    fi
    if [ -f /etc/systemd/system/docker.service ] &&
       grep -Eq '^ExecStart=(/usr/bin/dockerd|/usr/local/lib/docker-tools/static/dockerd)$' /etc/systemd/system/docker.service; then
        rm -f /etc/systemd/system/docker.service || return 1
        if [ "$report_removed" -eq 1 ]; then
            echo -e "${YELLOW}已删除：/etc/systemd/system/docker.service${NC}"
        fi
        service_removed=1
    fi

    local cli_path
    for cli_path in "$DOCKER_STATIC_CLI" "$DOCKER_STATIC_COMPAT_CLI"; do
        if [ -L "$cli_path" ] &&
           [ "$(readlink "$cli_path")" = "$DOCKER_STATIC_DIR/docker" ]; then
            rm -f "$cli_path" || return 1
            if [ "$report_removed" -eq 1 ]; then
                echo -e "${YELLOW}已删除：$cli_path${NC}"
            fi
        fi
    done
    if [ -d "$DOCKER_STATIC_DIR" ]; then
        if [ "$report_removed" -eq 1 ]; then
            while IFS= read -r removed_path; do
                static_paths+=("$removed_path")
            done < <(find "$DOCKER_STATIC_DIR" -depth -print)
        fi
        rm -rf "$DOCKER_STATIC_DIR" || return 1
        if [ "$report_removed" -eq 1 ]; then
            for removed_path in "${static_paths[@]}"; do
                echo -e "${YELLOW}已删除：$removed_path${NC}"
            done
        fi
    fi

    for path in "${docker_files[@]}"; do
        if { [ -f "$path" ] || [ -L "$path" ]; } && [ -z "$(get_package_owner "$path" || true)" ]; then
            rm -f "$path" || return 1
            if [ "$report_removed" -eq 1 ]; then
                echo -e "${YELLOW}已删除：$path${NC}"
            fi
        fi
    done
    if [ "$legacy_static" -eq 1 ]; then
        for path in "${runtime_files[@]}"; do
            if { [ -f "$path" ] || [ -L "$path" ]; } && [ -z "$(get_package_owner "$path" || true)" ]; then
                rm -f "$path" || return 1
                if [ "$report_removed" -eq 1 ]; then
                    echo -e "${YELLOW}已删除：$path${NC}"
                fi
            fi
        done
    fi

    if [ "$service_removed" -eq 1 ] && systemd_is_running; then
        systemctl daemon-reload || return 1
    fi
    return 0
}

# 恢复旧版静态安装可能覆盖的系统运行时软件包。
restore_legacy_runtime_packages() {
    [ -f "$DOCKER_LEGACY_RUNTIME_MARKER" ] || return 0

    local path owner
    local owners=()
    local runtime_files=(
        /usr/bin/docker /usr/bin/dockerd /usr/bin/containerd
        /usr/bin/containerd-shim /usr/bin/containerd-shim-runc-v1
        /usr/bin/containerd-shim-runc-v2 /usr/bin/ctr /usr/bin/runc
    )
    for path in "${runtime_files[@]}"; do
        owner="$(get_package_owner "$path" || true)"
        if [ -n "$owner" ] && [[ " ${owners[*]} " != *" $owner "* ]]; then
            owners+=("$owner")
        fi
    done

    if [ "${#owners[@]}" -gt 0 ]; then
        echo -e "${YELLOW}恢复旧版静态安装可能覆盖的系统运行时文件...${NC}"
        if ! get_package_manager >/dev/null 2>&1; then
            echo -e "${RED}无法恢复包管理器维护的旧 Docker 运行时文件。${NC}"
            return 1
        fi
        package_manager_reinstall "${owners[@]}" || return 1
    fi

    rm -f "$DOCKER_LEGACY_RUNTIME_MARKER" || return 1
}

# 安装包管理器版本的 Docker 前，清除冲突的静态安装文件。
prepare_package_manager_install() {
    cleanup_static_docker_files || return 1
    restore_legacy_runtime_packages
}

# 创建并验证包管理器 Docker 命令的兼容软链接。
ensure_package_docker_symlink() {
    local link_path="/usr/local/bin/docker"
    local target_path="/usr/bin/docker"
    local owner

    if [ ! -x "$target_path" ]; then
        echo -e "${RED}包管理器安装后未找到可执行文件：$target_path，无法创建 Docker 命令软链接。${NC}"
        return 1
    fi

    mkdir -p /usr/local/bin || {
        echo -e "${RED}无法创建目录：/usr/local/bin${NC}"
        return 1
    }

    if [ -L "$link_path" ]; then
        rm -f "$link_path" || {
            echo -e "${RED}无法移除旧 Docker 命令软链接：$link_path${NC}"
            return 1
        }
    elif [ -e "$link_path" ]; then
        owner="$(get_package_owner "$link_path" || true)"
        if [ -n "$owner" ]; then
            echo -e "${RED}${link_path} 由软件包 ${owner} 管理，拒绝覆盖。${NC}"
            return 1
        fi
        rm -f "$link_path" || {
            echo -e "${RED}无法移除旧 Docker 文件：$link_path${NC}"
            return 1
        }
    fi

    if ! ln -s "$target_path" "$link_path"; then
        echo -e "${RED}创建 Docker 命令软链接失败：$link_path -> $target_path${NC}"
        return 1
    fi
    echo -e "${GREEN}已创建 Docker 命令软链接：$link_path -> $target_path${NC}"
    hash -r

    if [ ! -x "$link_path" ] || [ "$(readlink "$link_path")" != "$target_path" ]; then
        echo -e "${RED}Docker 命令软链接验证失败：$link_path${NC}"
        return 1
    fi
}

# 检查系统中是否存在 Docker 命令。
check_docker_installed() {
    if command -v docker &> /dev/null || \
       [ -f /usr/bin/docker ] || \
       [ -f /usr/local/bin/docker ]; then
        return 0
    else
        return 1
    fi
}

# 获取指定镜像源发布的 Docker 版本列表。
get_all_docker_versions() {
    local base_url=$1
    wget -qO- "$base_url" | grep -oP 'docker-\d+\.\d+\.\d+\.tgz' | sed 's/docker-\(.*\)\.tgz/\1/' | sort -Vru 2>/dev/null
}

# 将版本列表按列排版输出。
display_versions_in_columns() {
    local versions=("$@")
    local columns=5     # 每行显示的列数
    local total=${#versions[@]}
    local rows=$(( (total + columns - 1) / columns ))

    for ((i = 0; i < rows; i++)); do
        for ((j = i; j < total; j += rows)); do
            printf "%-15s" "$((j + 1))) ${versions[j]}"
        done
        echo
    done
}

# 根据发行版通过系统包管理器安装 Docker Engine，不主动安装 Compose。
install_docker_from_package_manager() {
    echo -e "${YELLOW}通过系统包管理器安装 Docker Engine...${NC}"

    if [ "$(uname -s)" = "FreeBSD" ]; then
        echo -e "${RED}FreeBSD 不支持原生 Docker Engine；pkg 可用于安装 Compose/Buildx 工具，但不能提供 Linux Docker 守护进程。${NC}"
        return 1
    fi

    local os_id="" os_like="" package_name="" install_ok=0
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        os_id="${ID,,}"
        os_like="${ID_LIKE,,}"
    fi

    # 根据发行版选择发行版原生 Docker 包，避免混用 Docker CE 与系统自带 Docker。
    case "$os_id" in
        ubuntu|debian|linuxmint|pop)
            if ! command -v apt-get >/dev/null 2>&1; then
                echo -e "${RED}当前系统属于 Debian 系，但未找到 apt-get。${NC}"
                return 1
            fi
            ensure_dev_null || return 1
            apt-get update || return 1
            prepare_package_manager_install || return 1
            package_name="docker.io"
            apt-get install -y "$package_name" || return 1
            ;;
        fedora)
            if command -v dnf >/dev/null 2>&1; then
                prepare_package_manager_install || return 1
                package_name="moby-engine"
                dnf install -y "$package_name" || {
                    echo -e "${RED}安装 moby-engine 失败；请检查 Fedora 软件源是否提供该软件包。${NC}"
                    return 1
                }
            else
                echo -e "${RED}Fedora 系统未找到 dnf。${NC}"
                return 1
            fi
            ;;
        rhel|centos|rocky|almalinux|ol|amzn)
            prepare_package_manager_install || return 1
            if command -v dnf >/dev/null 2>&1; then
                package_name="moby-engine"
                dnf install -y "$package_name" || return 1
            elif command -v yum >/dev/null 2>&1; then
                package_name="moby-engine"
                yum install -y "$package_name" || return 1
            else
                echo -e "${RED}当前 RHEL 系统未找到 dnf 或 yum。${NC}"
                return 1
            fi
            ;;
        arch|manjaro|endeavouros)
            command -v pacman >/dev/null 2>&1 || {
                echo -e "${RED}未找到 pacman。${NC}"; return 1;
            }
            prepare_package_manager_install || return 1
            pacman -Sy --needed --noconfirm docker || return 1
            package_name="docker"
            ;;
        opensuse*|sles)
            command -v zypper >/dev/null 2>&1 || {
                echo -e "${RED}未找到 zypper。${NC}"; return 1;
            }
            zypper --non-interactive refresh || return 1
            prepare_package_manager_install || return 1
            zypper --non-interactive install docker || return 1
            package_name="docker"
            ;;
        alpine)
            command -v apk >/dev/null 2>&1 || {
                echo -e "${RED}未找到 apk。${NC}"; return 1;
            }
            prepare_package_manager_install || return 1
            apk add docker || return 1
            package_name="docker"
            ;;
        openwrt|istoreos|istore)
            command -v opkg >/dev/null 2>&1 || {
                echo -e "${RED}OpenWrt 系统未找到 opkg。${NC}"
                return 1
            }
            package_manager_update || return 1
            prepare_package_manager_install || return 1
            package_manager_install dockerd docker || return 1
            package_name="dockerd docker"
            ;;
        *)
            # 对衍生发行版按 ID_LIKE 字段识别，并使用对应的软件包名称。
            if [[ "$os_like" == *debian* ]] && command -v apt-get >/dev/null 2>&1; then
                ensure_dev_null || return 1
                apt-get update || return 1
                prepare_package_manager_install || return 1
                apt-get install -y docker.io || return 1
                package_name="docker.io"
            elif [[ "$os_like" == *rhel* || "$os_like" == *redhat* || "$os_like" == *fedora* || "$os_like" == *centos* ]] && command -v dnf >/dev/null 2>&1; then
                prepare_package_manager_install || return 1
                dnf install -y moby-engine || return 1
                package_name="moby-engine"
            elif [[ "$os_like" == *rhel* || "$os_like" == *redhat* || "$os_like" == *fedora* || "$os_like" == *centos* ]] && command -v yum >/dev/null 2>&1; then
                prepare_package_manager_install || return 1
                yum install -y moby-engine || return 1
                package_name="moby-engine"
            elif [[ "$os_like" == *suse* ]] && command -v zypper >/dev/null 2>&1; then
                zypper --non-interactive refresh || return 1
                prepare_package_manager_install || return 1
                zypper --non-interactive install docker || return 1
                package_name="docker"
            elif [[ "$os_like" == *openwrt* ]] && command -v opkg >/dev/null 2>&1; then
                package_manager_update || return 1
                prepare_package_manager_install || return 1
                package_manager_install dockerd docker || return 1
                package_name="dockerd docker"
            else
                echo -e "${RED}暂不支持该发行版的自动包管理器安装：${os_id:-unknown}${NC}"
                echo -e "${YELLOW}请使用二进制安装方式，或先配置该发行版的 Docker 软件源。${NC}"
                return 1
            fi
            ;;
    esac

    ensure_package_docker_symlink || return 1
    hash -r
    if ! command -v docker >/dev/null 2>&1 || ! docker --version >/dev/null 2>&1; then
        echo -e "${RED}软件包安装完成，但未找到可运行的 docker 命令。${NC}"
        return 1
    fi

    # 分别处理 systemd 和 OpenRC，避免在 Alpine 等系统调用不存在的 systemctl。
    if systemd_is_running; then
        if ! unmask_docker_units; then
            echo -e "${RED}无法解除 Docker systemd 服务屏蔽。${NC}"
            return 1
        fi
        if ! systemctl daemon-reload; then
            echo -e "${RED}重新加载 systemd 配置失败。${NC}"
            return 1
        fi
        if systemctl enable --now docker.service; then
            install_ok=1
        else
            echo -e "${YELLOW}Docker 已安装，但服务启动失败。请检查：journalctl -u docker。${NC}"
        fi
    elif command -v rc-update >/dev/null 2>&1; then
        if ! rc-update add docker default; then
            echo -e "${RED}无法将 Docker 服务添加到 OpenRC 默认运行级别。${NC}"
            return 1
        fi
        if service docker start; then
            install_ok=1
        else
            echo -e "${YELLOW}Docker 已安装，但 OpenRC 服务启动失败。${NC}"
        fi
    elif [ -x /etc/init.d/dockerd ]; then
        if /etc/init.d/dockerd enable && /etc/init.d/dockerd start; then
            install_ok=1
        else
            echo -e "${YELLOW}Docker 已安装，但 OpenWrt dockerd 服务启动失败。${NC}"
        fi
    elif command -v service >/dev/null 2>&1; then
        if service docker start; then
            install_ok=1
        else
            echo -e "${YELLOW}Docker 已安装，但服务启动失败。${NC}"
        fi
    fi

    echo -e "${GREEN}Docker Engine 包管理器安装完成。${NC}"
    docker --version

    if [ "$install_ok" -eq 1 ] && docker info >/dev/null 2>&1; then
        echo -e "${GREEN}Docker 服务运行正常。${NC}"
    else
        echo -e "${YELLOW}Docker 命令已安装；服务状态尚未确认正常，请检查服务日志及系统权限。${NC}"
        return 1
    fi
    echo -e "${BLUE}Compose 未随 Docker Engine 自动安装，可通过主菜单单独安装 Compose。${NC}"
    return 0
}

# 执行 Docker 安装主流程，并处理重装及安装方式选择。
install_docker_core() {
    local specific_version=$1

    if [ "$(uname -s)" = "FreeBSD" ]; then
        echo -e "${RED}此脚本不能在 FreeBSD 上安装 Docker Engine；FreeBSD 的 pkg 仅用于管理可用的 Compose/Buildx 软件包。${NC}"
        return 1
    fi

    # 检查系统中是否已安装 Docker。
    if check_docker_installed; then
        echo -e "${YELLOW}Docker 已安装在系统中。${NC}"
        if command -v docker &> /dev/null; then
            docker --version
        fi
        if ! confirm "是否需要卸载现有 Docker 并重新安装？"; then
            echo -e "${GREEN}用户选择保留现有Docker环境。${NC}"
            return 1
        fi

        # 用户确认重新安装后，先执行卸载操作。
        echo -e "${YELLOW}开始卸载现有 Docker 环境...${NC}"
        if ! uninstall_docker_core; then
            echo -e "${RED}Docker 卸载未完成，已取消重新安装。${NC}"
            return 1
        fi
        # 卸载后刷新命令缓存，避免后续检测到旧路径。
        hash -r
        # 再次检查，确认卸载后的环境已清理。
        if check_docker_installed; then
            echo -e "${RED}Docker卸载失败，请检查系统环境。${NC}"
            return 1
        fi
        echo -e "${GREEN}现有 Docker 环境已成功卸载。${NC}"

        # 卸载后询问用户是否继续安装。
        if ! confirm "是否继续安装 Docker？"; then
            echo -e "${GREEN}用户选择跳过安装。${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}未检测到 Docker 环境。${NC}"
        if ! confirm "是否需要安装 Docker？"; then
            echo -e "${GREEN}用户选择跳过安装。${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}开始安装 Docker...${NC}"

    # 获取系统架构。
    arch_suffix=$(get_system_arch)
    if [ $? -ne 0 ]; then
        echo -e "${RED}无法确定适合您系统的Docker版本。${NC}"
        return 1
    fi

    echo -e "${BLUE}检测到系统架构: $(uname -m)${NC}"

    # 指定版本仅支持静态二进制安装；普通安装提供包管理器和二进制两种方式。
    if [ -z "$specific_version" ]; then
        local docker_install_method=""
        while true; do
            echo -e "${GREEN}请选择 Docker 安装方式：${NC}"
            echo "1. 通过系统包管理器安装（默认，推荐）"
            echo "2. 使用本地/下载的静态二进制安装包"
            read -r -p "请选择安装方式 (1/2，默认1): " docker_install_method
            case "$docker_install_method" in
                1|"")
                    install_docker_from_package_manager
                    return $?
                    ;;
                2)
                    break
                    ;;
                *)
                    echo -e "${RED}无效的选择，请输入 1 或 2。${NC}"
                    ;;
            esac
        done
    else
        echo -e "${BLUE}指定版本安装使用静态二进制安装包方式。${NC}"
    fi

    local package_name=""
    local working_mirror=""
    local download_url=""

    if [ -z "$specific_version" ]; then
        # 获取最新版本。
        for mirror in "${DOCKER_MIRRORS[@]}"; do
            local full_url="$mirror/$arch_suffix"
            echo -e "${YELLOW}尝试从镜像源获取版本: $full_url${NC}"
            package_name=$(wget -qO- "$full_url" | grep -oP 'docker-\d+\.\d+\.\d+\.tgz' | sort -Vr | head -n 1)
            if [ -n "$package_name" ]; then
                working_mirror="$full_url"
                download_url="$working_mirror/$package_name"
                echo -e "${GREEN}找到最新版本: $package_name${NC}"
                break
            fi
            echo -e "${YELLOW}镜像源 $full_url 无可用版本，尝试下一个...${NC}"
        done
    else
        # 检查本地是否存在指定版本的安装包。
        package_name="docker-$specific_version.tgz"
        if [ -f "$package_name" ]; then
            echo -e "${GREEN}在本地找到指定版本的安装包: $package_name${NC}"
        else
            # 获取指定版本。
            for mirror in "${DOCKER_MIRRORS[@]}"; do
                local full_url="$mirror/$arch_suffix"
                echo -e "${YELLOW}尝试从镜像源获取版本: $full_url${NC}"
                if wget --spider "$full_url/$package_name" 2>/dev/null; then
                    working_mirror="$full_url"
                    download_url="$working_mirror/$package_name"
                    echo -e "${GREEN}找到指定版本: $package_name${NC}"
                    break
                fi
                echo -e "${YELLOW}镜像源 $full_url 无可用版本，尝试下一个...${NC}"
            done
        fi
    fi

    if [ -z "$package_name" ]; then
        echo -e "${RED}无法获取Docker版本，请检查网络或手动下载。${NC}"
        return 1
    fi

    # 本地没有 Docker 安装包时下载文件。
    if [ ! -f "$package_name" ]; then
        echo -e "${YELLOW}正在下载 $package_name ...${NC}"
        if ! wget "$download_url"; then
            echo -e "${RED}下载失败，请检查网络连接。${NC}"
            return 1
        fi
        echo -e "${GREEN}安装包下载成功: $package_name${NC}"
    fi

    if ! systemd_is_running; then
        echo -e "${RED}静态二进制安装需要正在运行的 systemd；请改用系统包管理器安装。${NC}"
        return 1
    fi

    local install_stage source_dir binary required_binary cli_path
    for cli_path in "$DOCKER_STATIC_CLI" "$DOCKER_STATIC_COMPAT_CLI"; do
        if [ -e "$cli_path" ] || [ -L "$cli_path" ]; then
            if [ ! -L "$cli_path" ] || [ "$(readlink "$cli_path")" != "$DOCKER_STATIC_DIR/docker" ]; then
                echo -e "${RED}$cli_path 已存在且不属于脚本管理，拒绝覆盖。${NC}"
                return 1
            fi
        fi
    done
    mkdir -p "$(dirname "$DOCKER_STATIC_DIR")" /usr/local/bin || {
        echo -e "${RED}无法创建静态 Docker 安装目录。${NC}"
        return 1
    }

    # 将安装包内的运行时组件集中存放，避免与包管理器文件混用。
    install_stage=$(mktemp -d "$(dirname "$DOCKER_STATIC_DIR")/.docker-install.XXXXXX") || {
        echo -e "${RED}无法创建 Docker 安装暂存目录。${NC}"
        return 1
    }

    echo -e "${YELLOW}解压Docker安装包...${NC}"
    if ! tar -zxf "$package_name" -C "$install_stage"; then
        echo -e "${RED}Docker安装包解压失败。${NC}"
        rm -rf "$install_stage"
        return 1
    fi

    source_dir="$install_stage/docker"
    if [ ! -d "$source_dir" ]; then
        echo -e "${RED}安装包中未找到 docker 可执行文件目录。${NC}"
        rm -rf "$install_stage"
        return 1
    fi
    for required_binary in docker dockerd containerd runc; do
        if [ ! -f "$source_dir/$required_binary" ]; then
            echo -e "${RED}安装包缺少必需的可执行文件：$required_binary${NC}"
            rm -rf "$install_stage"
            return 1
        fi
    done
    if [ ! -f "$source_dir/containerd-shim-runc-v2" ] &&
       [ ! -f "$source_dir/containerd-shim-runc-v1" ] &&
       [ ! -f "$source_dir/containerd-shim" ]; then
        echo -e "${RED}安装包缺少 containerd shim 可执行文件。${NC}"
        rm -rf "$install_stage"
        return 1
    fi

    if ! cleanup_static_docker_files; then
        echo -e "${RED}清理旧版 Docker 静态安装文件失败。${NC}"
        rm -rf "$install_stage"
        return 1
    fi

    # 解除已有的 systemd 屏蔽状态，避免服务文件写入后仍无法启动。
    if ! unmask_docker_units; then
        echo -e "${RED}无法解除 Docker systemd 服务屏蔽。${NC}"
        rm -rf "$install_stage"
        return 1
    fi

    systemctl stop docker.socket docker.service >/dev/null 2>&1 || true

    echo -e "${YELLOW}安装隔离的Docker可执行文件...${NC}"
    for binary in "$source_dir"/*; do
        [ -f "$binary" ] || continue
        if ! chmod 755 "$binary"; then
            echo -e "${RED}设置可执行文件权限失败：$(basename "$binary")${NC}"
            rm -rf "$install_stage"
            return 1
        fi
    done

    rm -rf "$DOCKER_STATIC_DIR"
    if ! mv "$source_dir" "$DOCKER_STATIC_DIR"; then
        echo -e "${RED}移动 Docker 可执行文件到安装目录失败。${NC}"
        rm -rf "$install_stage"
        return 1
    fi
    rm -rf "$install_stage"
    echo -e "${GREEN}Docker 二进制安装目录：$DOCKER_STATIC_DIR${NC}"
    local installed_binary
    for installed_binary in "$DOCKER_STATIC_DIR"/*; do
        [ -f "$installed_binary" ] || continue
        echo -e "${GREEN}Docker 可执行文件：$installed_binary${NC}"
    done
    for cli_path in "$DOCKER_STATIC_CLI" "$DOCKER_STATIC_COMPAT_CLI"; do
        if ! ln -sfn "$DOCKER_STATIC_DIR/docker" "$cli_path"; then
            echo -e "${RED}创建 Docker 命令链接失败：$cli_path${NC}"
            return 1
        fi
        echo -e "${GREEN}Docker 命令链接：$cli_path -> $DOCKER_STATIC_DIR/docker${NC}"
    done
    export PATH="/usr/local/bin:$PATH"
    hash -r

    # 创建 Docker systemd 服务文件。
    echo -e "${YELLOW}创建Docker服务文件...${NC}"
    if ! cat > /etc/systemd/system/docker.service <<EOF
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
Environment=PATH=$DOCKER_STATIC_DIR:/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin
ExecStart=$DOCKER_STATIC_DIR/dockerd
ExecReload=/bin/kill -s HUP \$MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF
    then
        echo -e "${RED}写入 Docker 服务文件失败。${NC}"
        return 1
    fi

    # 设置服务文件权限。
    if ! chmod 644 /etc/systemd/system/docker.service; then
        echo -e "${RED}设置 Docker 服务文件权限失败。${NC}"
        return 1
    fi

    # 重新加载 systemd 配置、启动服务并设置开机自启。
    if ! systemctl daemon-reload || ! systemctl enable --now docker.service; then
        echo -e "${RED}Docker服务启动或设置开机启动失败，请检查：journalctl -u docker.service。${NC}"
        return 1
    fi

    # 显示 Docker 版本。
    echo -e "${YELLOW}正在检查Docker版本...${NC}"
    docker_version=$(docker --version 2>&1)
    if [ $? -ne 0 ] || ! docker info >/dev/null 2>&1; then
        echo -e "${RED}Docker命令已安装，但无法连接到Docker守护进程。请检查：journalctl -u docker.service。${NC}"
        return 1
    fi

    echo -e "${GREEN}Docker安装完成，版本信息如下：${NC}"
    echo "$docker_version"

    # 询问用户是否删除已下载的安装包。
    if confirm "是否删除当前目录下的安装包 $package_name？"; then
        rm -f "$package_name"
        echo -e "${GREEN}安装包 $package_name 已删除。${NC}"
    else
        echo -e "${GREEN}安装包 $package_name 保留。${NC}"
    fi
}

# 卸载 Docker 组件，并清理残留配置、运行数据和用户环境。
docker_clean_all() {
    echo -e "${GREEN}"
    echo "=============================================="
    echo "       完整卸载并清理 Docker 环境"
    echo "=============================================="
    echo -e "${NC}"
    echo -e "${RED}警告：此操作将卸载 Docker、Compose、Buildx 等 Docker 专属组件，并永久删除容器、镜像、卷及配置。${NC}"
    echo -e "${RED}将清理 /var/lib/docker、/var/lib/containerd，以及所有可发现用户的 Docker 配置、凭据和 rootless 数据，并可能中断其他使用 containerd 的运行时。${NC}"
    echo -e "${YELLOW}为避免影响其他软件，不会强制卸载可能共享的通用 containerd、runc 或系统库。${NC}"

    if ! confirm_default_no "确认继续完整卸载并删除上述 Docker 数据？"; then
        echo -e "${GREEN}已取消操作，未主动删除 Docker 数据。${NC}"
        return 0
    fi
    local confirmation
    read -r -p "此操作不可恢复，请输入 DELETE 确认：" confirmation
    if [ "$(echo "$confirmation" | tr 'a-z' 'A-Z')" != "DELETE" ]; then
        echo -e "${GREEN}确认文本不匹配，已取消操作。${NC}"
        return 0
    fi

    echo -e "${YELLOW}正在停止 Docker/containerd 服务...${NC}"
    if systemd_is_running; then
        local unit
        for unit in docker.socket docker.service containerd.service; do
            if systemctl is-active --quiet "$unit"; then
                systemctl stop "$unit" || {
                    echo -e "${RED}停止服务失败：$unit${NC}"
                    return 1
                }
                echo -e "${GREEN}已停止服务：$unit${NC}"
            fi
        done
        for unit in docker.socket docker.service; do
            case "$(systemctl is-enabled "$unit" 2>/dev/null || true)" in
                enabled|enabled-runtime|linked|linked-runtime|alias)
                    systemctl disable "$unit" || {
                        echo -e "${RED}禁用服务失败：$unit${NC}"
                        return 1
                    }
                    ;;
            esac
        done
    else
        local service_name service_script
        for service_name in docker dockerd containerd; do
            service_script="/etc/init.d/$service_name"
            if command -v rc-service >/dev/null 2>&1 && rc-service "$service_name" status >/dev/null 2>&1; then
                rc-service "$service_name" stop || {
                    echo -e "${RED}停止服务失败：$service_name${NC}"
                    return 1
                }
                echo -e "${GREEN}已停止服务：$service_name${NC}"
            elif [ -x "$service_script" ] && "$service_script" status >/dev/null 2>&1; then
                "$service_script" stop || {
                    echo -e "${RED}停止服务失败：$service_name${NC}"
                    return 1
                }
                echo -e "${GREEN}已停止服务：$service_name${NC}"
            fi
            if command -v rc-update >/dev/null 2>&1; then
                rc-update del "$service_name" default >/dev/null 2>&1 || true
            fi
        done
    fi

    local manager
    manager="$(get_package_manager 2>/dev/null || true)"
    local packages=(
        docker docker.io docker-ce docker-ce-cli docker-ce-rootless-extras docker-engine
        docker-ce-selinux docker-engine-selinux docker-rootless-extras docker-scan-plugin
        docker-buildx-plugin docker-buildx docker-cli-buildx docker-compose-plugin
        docker-compose-v2 docker-cli-compose docker-compose docker-compose-bin dockerd
        moby-engine moby-cli moby-buildx moby-compose moby-containerd moby-runc
        containerd.io
    )
    local package
    if [ -n "$manager" ]; then
        for package in "${packages[@]}"; do
            if package_is_installed "$package"; then
                remove_package_with_report "$package" || return 1
            fi
        done
    else
        echo -e "${YELLOW}未检测到支持的包管理器，将清理可识别的静态安装文件和残留路径。${NC}"
    fi

    cleanup_static_docker_files report || return 1

    local unowned_paths=(
        /usr/bin/docker-proxy /usr/local/bin/docker-proxy
        /usr/bin/docker-init /usr/local/bin/docker-init
    )
    local owner
    for path in "${unowned_paths[@]}"; do
        if { [ -e "$path" ] || [ -L "$path" ]; } &&
           [ -z "$(get_package_owner "$path" || true)" ]; then
            remove_path_with_report "$path" || return 1
        fi
    done

    local paths=(
        /etc/docker
        /etc/default/docker
        /etc/sysconfig/docker
        /etc/sysconfig/docker-storage
        /etc/sysconfig/docker-network
        /etc/conf.d/docker
        /etc/conf.d/dockerd
        /etc/config/dockerd
        /etc/init.d/docker
        /etc/init.d/dockerd
        /etc/systemd/system/docker.service
        /etc/systemd/system/docker.socket
        /etc/systemd/system/docker.service.d
        /etc/systemd/system/docker.socket.d
        /etc/systemd/system/docker.service.wants
        /etc/systemd/system/docker.service.requires
        /etc/systemd/system/multi-user.target.wants/docker.service
        /etc/systemd/system/sockets.target.wants/docker.socket
        /usr/local/bin/docker-compose
        /usr/bin/docker-compose
        /usr/local/bin/docker-buildx
        /usr/bin/docker-buildx
        /usr/local/lib/docker
        /usr/local/libexec/docker
        /usr/lib/docker
        /usr/libexec/docker
        /var/lib/docker
        /var/lib/containerd
        /run/docker
        /run/docker.sock
        /var/run/docker
        /var/run/docker.sock
        "$DOCKER_LEGACY_RUNTIME_MARKER"
    )
    local path
    unmount_docker_netns_mounts || return 1
    for path in "${paths[@]}"; do
        remove_path_with_report "$path" || return 1
    done
    if [ -d /var/lib/docker-tools ] && rmdir /var/lib/docker-tools 2>/dev/null; then
        echo -e "${GREEN}已删除空目录：/var/lib/docker-tools${NC}"
    fi

    for path in /etc/rc*.d/*docker* /etc/rc*.d/*dockerd* /etc/runlevels/*/docker /etc/runlevels/*/dockerd; do
        remove_path_with_report "$path" || return 1
    done

    if command -v getent >/dev/null 2>&1; then
        remove_user_docker_environment < <(getent passwd) || return 1
    else
        local user_home
        for user_home in /root /home/* "$HOME"; do
            if [ -d "$user_home" ]; then
                printf 'fallback:x:1000:1000::%s:/bin/sh\n' "$user_home" |
                    remove_user_docker_environment || return 1
            fi
        done
    fi

    if systemd_is_running; then
        systemctl daemon-reload || {
            echo -e "${RED}重新加载 systemd 配置失败。${NC}"
            return 1
        }
    fi
    hash -r

    local remaining=0
    if [ -n "$manager" ]; then
        for package in "${packages[@]}"; do
            if package_is_installed "$package"; then
                echo -e "${RED}仍检测到 Docker 软件包：$package${NC}"
                remaining=1
            fi
        done
    fi
    if command -v docker >/dev/null 2>&1; then
        echo -e "${RED}仍检测到 Docker 命令：$(command -v docker)${NC}"
        remaining=1
    fi
    for package in dockerd docker-compose docker-buildx docker-proxy docker-init dockerd-rootless.sh; do
        if command -v "$package" >/dev/null 2>&1; then
            echo -e "${RED}仍检测到 Docker 相关命令：$(command -v "$package")${NC}"
            remaining=1
        fi
    done
    if [ "$remaining" -ne 0 ]; then
        echo -e "${RED}清理未能完全完成，请根据上述残留信息手动处理。${NC}"
        return 1
    fi

    if [ -n "$manager" ] && { package_is_installed containerd || package_is_installed runc; }; then
        echo -e "${YELLOW}安全策略保留了通用 containerd/runc 软件包；它们可能被 Kubernetes 等其他软件使用。${NC}"
    fi

    echo -e "${GREEN}Docker 专属组件、配置和数据清理完成。${NC}"
    return 0
}

# 执行 Docker 卸载主流程，并保留用户确认的数据目录。
uninstall_docker_core() {
    echo -e "${GREEN}"
    echo "=============================================="
    echo "           Docker 卸载警告"
    echo "=============================================="
    echo -e "${NC}此操作将执行以下步骤："
    echo "1. 停止Docker服务"
    echo "2. 禁用Docker开机自启"
    echo "3. 删除Docker相关可执行文件"
    echo "4. 删除Docker配置文件"
    echo "5. 删除Docker systemd服务文件"
    echo ""
    echo -e "${RED}注意：默认情况下不会删除/var/lib/docker目录，这包含所有的镜像、容器和卷数据。${NC}"
    echo -e "${GREEN}=============================================="
    echo -e "${NC}"

    if ! check_docker_installed; then
        echo -e "${RED}未检测到Docker安装，无需卸载。${NC}"
        return 1
    fi

    echo -e "${GREEN}检测到系统已安装Docker。${NC}"
    if command -v docker &> /dev/null; then
        docker --version
    fi

    if ! confirm "确定要卸载Docker吗"; then
        echo -e "${GREEN}已取消卸载操作。${NC}"
        return 1
    fi

    echo -e "${GREEN}开始卸载Docker...${NC}"

    local docker_cmd="" package_owner="" path
    docker_cmd="$(command -v docker 2>/dev/null || true)"
    local package_owners=()
    local package_paths=("$docker_cmd" /usr/bin/docker /usr/local/bin/docker /usr/bin/dockerd /usr/local/bin/dockerd)
    for path in "${package_paths[@]}"; do
        [ -n "$path" ] || continue
        package_owner="$(get_package_owner "$path" || true)"
        if [ -n "$package_owner" ] && [[ " ${package_owners[*]} " != *" $package_owner "* ]]; then
            package_owners+=("$package_owner")
        fi
    done

    if systemd_is_running; then
        systemctl stop docker.socket docker.service >/dev/null 2>&1 || true
        systemctl disable docker.service >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service docker stop >/dev/null 2>&1 || true
    fi

    if [ "${#package_owners[@]}" -gt 0 ]; then
        echo -e "${YELLOW}检测到包管理器安装的 Docker 软件包：${package_owners[*]}。${NC}"
        echo -e "${YELLOW}通过包管理器卸载，以保留其余系统管理的运行时文件。${NC}"
        if ! get_package_manager >/dev/null 2>&1; then
            echo -e "${RED}未找到可卸载 Docker 软件包的包管理器。${NC}"
            return 1
        fi
        for package_owner in "${package_owners[@]}"; do
            package_manager_remove "$package_owner" || return 1
        done
    fi

    # 仅删除本脚本创建的服务单元。
    cleanup_static_docker_files report || return 1

    if systemd_is_running; then
        systemctl daemon-reload || return 1
    fi

    hash -r

    # 此危险操作的默认选项为“否”。
    if confirm_default_no "是否要删除Docker数据目录(/var/lib/docker)？这将删除所有镜像、容器和卷数据"; then
        echo -e "${YELLOW}删除Docker数据目录...${NC}"
        rm -rf /var/lib/docker || return 1
        echo -e "${YELLOW}已删除：/var/lib/docker${NC}"
    else
        echo -e "${GREEN}保留Docker数据目录(/var/lib/docker)${NC}"
    fi
    
    echo -e "${GREEN}Docker卸载完成!${NC}"
    return 0
}

# 指定 Docker CLI 官方插件目录，供 Compose 插件安装流程使用。
DOCKER_COMPOSE_PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"

# 检查 Docker Compose V2 插件是否可用。
check_docker_compose_plugin() {
    docker compose version >/dev/null 2>&1
}

# 检查独立的 docker-compose 命令是否可用。
check_docker_compose_legacy() {
    command -v docker-compose >/dev/null 2>&1 && docker-compose --version >/dev/null 2>&1
}

# 检查常见目录和命令入口中是否存在 Docker Compose。
check_docker_compose_installed() {
    check_docker_compose_plugin || check_docker_compose_legacy || \
    [ -x /usr/local/lib/docker/cli-plugins/docker-compose ] || \
    [ -x /usr/local/libexec/docker/cli-plugins/docker-compose ] || \
    [ -x /usr/lib/docker/cli-plugins/docker-compose ] || \
    [ -x /usr/libexec/docker/cli-plugins/docker-compose ] || \
    [ -x /usr/bin/docker-compose ] || [ -x /usr/local/bin/docker-compose ]
}

# 分别显示 Docker Compose 插件和兼容命令的版本。
show_docker_compose_version() {
    local result=0
    if check_docker_compose_plugin; then
        echo -n "docker compose："
        docker compose version
    else
        echo "docker compose：未安装或插件不可用"
        result=1
    fi

    if check_docker_compose_legacy; then
        echo -n "docker-compose："
        docker-compose --version
    else
        echo "docker-compose：未安装或不可用"
        result=1
    fi
    return "$result"
}

# 获取 Docker Compose 发布版本列表。
get_all_docker_compose_versions() {
    local latest_version=$(curl -s https://api.github.com/repos/docker/compose/releases | grep 'tag_name' | cut -d\" -f4 | sort -Vr)
    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取版本号列表${NC}" >&2
        return 1
    fi
    echo "$latest_version"
}

# 获取最新的 Docker Compose 发布版本。
get_latest_docker_compose_version() {
    local latest_version=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取最新版本号${NC}" >&2
        return 1
    fi
    echo "${latest_version}"
}

# 检查 /usr/local/bin 是否位于 PATH 中，并按需写入 Shell 配置。
check_and_add_to_path() {
    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        echo -e "${YELLOW}/usr/local/bin 不在 PATH 环境变量中${NC}"
        if confirm "是否要将 /usr/local/bin 添加到 PATH 环境变量中？"; then
            local shell_rc=""
            if [ -f "$HOME/.bashrc" ]; then
                shell_rc="$HOME/.bashrc"
            elif [ -f "$HOME/.zshrc" ]; then
                shell_rc="$HOME/.zshrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                shell_rc="$HOME/.bash_profile"
            elif [ -f "$HOME/.profile" ]; then
                shell_rc="$HOME/.profile"
            fi

            if [ -n "$shell_rc" ]; then
                echo -e "${YELLOW}添加 /usr/local/bin 到 PATH (在 $shell_rc 中)${NC}"
                echo 'export PATH="$PATH:/usr/local/bin"' >> "$shell_rc"
                source "$shell_rc"
                echo -e "${GREEN}PATH 已更新，需要重新打开终端或运行 'source $shell_rc' 使更改生效${NC}"
            else
                echo -e "${RED}未找到 .bashrc 或 .zshrc 文件，请手动添加:${NC}"
                echo -e "${BLUE}export PATH=\$PATH:/usr/local/bin${NC}"
                echo -e "${YELLOW}或执行以下命令临时生效:${NC}"
                echo -e "${BLUE}export PATH=\$PATH:/usr/local/bin${NC}"
            fi
        fi
    fi
}

# 使用系统包管理器安装 Docker Compose，优先选择 V2 插件。
install_with_package_manager() {
    echo -e "${YELLOW}尝试通过系统包管理器安装 Docker Compose V2 插件...${NC}"
    local manager
    local candidates=()
    manager="$(get_package_manager)" || {
        echo -e "${RED}未检测到支持的包管理器。${NC}"
        return 1
    }

    package_manager_update || return 1
    case "$manager" in
        apt) candidates=(docker-compose-plugin docker-compose-v2 docker-compose) ;;
        dnf|yum) candidates=(docker-compose-plugin docker-compose) ;;
        zypper|pacman|pkg|opkg) candidates=(docker-compose) ;;
        apk) candidates=(docker-cli-compose docker-compose) ;;
    esac

    local candidate
    for candidate in "${candidates[@]}"; do
        if package_manager_install "$candidate"; then
            hash -r
            if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
                break
            fi
        fi
    done

    hash -r
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        echo -e "${RED}未能通过 ${manager} 安装 Docker Compose；请确认软件源中存在兼容的软件包。${NC}"
        return 1
    fi

    if docker compose version >/dev/null 2>&1; then
        echo -e "${GREEN}Docker Compose V2 插件安装成功：${NC}"
        docker compose version
        return 0
    elif command -v docker-compose >/dev/null 2>&1; then
        echo -e "${GREEN}Docker Compose 独立版安装成功：${NC}"
        docker-compose --version
        return 0
    fi
    echo -e "${RED}安装命令执行后仍未检测到 Docker Compose，请检查软件源及 Docker CLI 插件目录。${NC}"
    return 1
}

# 将 Compose V2 二进制安装为 CLI 插件及兼容独立命令。
install_compose_binary_file() {
    local source_file="$1"
    local plugin_dir="/usr/local/lib/docker/cli-plugins"
    local plugin_file="${plugin_dir}/docker-compose"
    local legacy_file="/usr/local/bin/docker-compose"

    if [ ! -s "$source_file" ] || [ ! -x "$source_file" ]; then
        echo -e "${RED}Compose 二进制文件不存在、为空或不可执行。${NC}"
        return 1
    fi
    if ! "$source_file" --version >/dev/null 2>&1; then
        echo -e "${RED}Compose 二进制文件无法正常运行，拒绝安装。${NC}"
        return 1
    fi

    mkdir -p "$plugin_dir" /usr/local/bin || return 1
    install -m 0755 "$source_file" "$plugin_file" || return 1
    echo -e "${GREEN}Docker Compose 插件安装路径：$plugin_file${NC}"
    # 保留传统 docker-compose 命令；两个入口使用同一版本的 V2 程序
    ln -sfn "$plugin_file" "$legacy_file" || return 1
    echo -e "${GREEN}Docker Compose 兼容命令路径：$legacy_file -> $plugin_file${NC}"
    hash -r

    echo -e "${YELLOW}验证 Docker CLI 插件入口...${NC}"
    if ! docker compose version; then
        echo -e "${RED}插件文件已放置到 ${plugin_file}，但当前 Docker CLI 未能加载插件。${NC}"
        echo -e "${YELLOW}请确认 Docker CLI 支持 CLI plugins，并检查 docker --help 是否包含 compose。${NC}"
        return 1
    fi

    echo -e "${YELLOW}验证兼容命令入口...${NC}"
    if ! docker-compose --version; then
        echo -e "${RED}docker-compose 兼容命令验证失败。${NC}"
        return 1
    fi

    echo -e "${GREEN}Docker Compose V2 插件及兼容命令安装成功。${NC}"
    return 0
}

# 下载或使用本地二进制文件安装 Docker Compose V2。
install_with_binary() {
    echo -e "${YELLOW}准备通过二进制文件安装 Docker Compose V2...${NC}"

    local compose_version="$1"
    if [ -z "$compose_version" ]; then
        compose_version=$(get_latest_docker_compose_version) || {
            echo -e "${RED}无法获取最新版本号。${NC}"
            return 1
        }
    fi
    echo -e "${YELLOW}准备安装版本：${compose_version}${NC}"

    local arch_suffix
    arch_suffix=$(get_system_arch) || return 1
    local binary_filename="docker-compose-linux-${arch_suffix}"
    local source_file="./${binary_filename}"

    if [ ! -f "$source_file" ]; then
        local mirror_urls=(
            "https://gh-proxy.com/https://github.com/docker/compose/releases/download/${compose_version}/${binary_filename}"
            "https://ghproxy.net/https://github.com/docker/compose/releases/download/${compose_version}/${binary_filename}"
            "https://github.com/docker/compose/releases/download/${compose_version}/${binary_filename}"
        )
        local binary_url=""
        local sha256_url=""
        local url
        for url in "${mirror_urls[@]}"; do
            echo -e "${YELLOW}检查下载地址：${url}${NC}"
            if timeout 15s wget --spider -q "$url"; then
                binary_url="$url"
                if [[ "$url" == *"gh-proxy.com"* || "$url" == *"ghproxy.net"* ]]; then
                    sha256_url="${url}.sha256"
                else
                    sha256_url="https://github.com/docker/compose/releases/download/${compose_version}/${binary_filename}.sha256"
                fi
                break
            fi
        done
        if [ -z "$binary_url" ]; then
            echo -e "${RED}所有下载地址均不可用，请检查网络或放置本地二进制文件。${NC}"
            return 1
        fi

        echo -e "${YELLOW}正在下载 ${binary_filename}...${NC}"
        wget --show-progress "$binary_url" -O "$source_file" || {
            rm -f "$source_file"
            echo -e "${RED}Compose 二进制文件下载失败。${NC}"
            return 1
        }

        local checksum_file="${source_file}.sha256"
        if wget -q "$sha256_url" -O "$checksum_file"; then
            local expected_sha256 calculated_sha256
            expected_sha256=$(awk 'NR==1 {print $1}' "$checksum_file")
            calculated_sha256=$(sha256sum "$source_file" | awk '{print $1}')
            if [ -z "$expected_sha256" ] || [ "$expected_sha256" != "$calculated_sha256" ]; then
                echo -e "${RED}SHA256 校验失败，已取消安装。${NC}"
                rm -f "$source_file" "$checksum_file"
                return 1
            fi
            echo -e "${GREEN}SHA256 校验通过。${NC}"
            rm -f "$checksum_file"
        else
            echo -e "${YELLOW}无法下载 SHA256 校验文件。${NC}"
            if ! confirm "是否继续安装未校验的二进制文件？"; then
                rm -f "$source_file"
                return 1
            fi
        fi
    else
        echo -e "${GREEN}检测到本地安装包：${source_file}${NC}"
        if [ -f "${source_file}.sha256" ]; then
            if ! (cd "$(dirname "$source_file")" && sha256sum -c "$(basename "${source_file}").sha256"); then
                echo -e "${RED}本地文件 SHA256 校验失败。${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}本地文件没有 SHA256 校验文件。${NC}"
            if ! confirm "是否继续安装？"; then return 1; fi
        fi
    fi

    chmod 0755 "$source_file" || return 1
    if ! install_compose_binary_file "$source_file"; then
        return 1
    fi

    check_and_add_to_path
    echo -e "${GREEN}[Compose版本信息]${NC}"
    show_docker_compose_version
    return $?
}

# 执行 Docker Compose 安装主流程并处理安装方式选择。
install_docker_compose_core() {
    # 检查系统中是否已安装 Docker Compose。
    if check_docker_compose_installed; then
        echo -e "${YELLOW}Docker Compose 已安装在系统中。${NC}"
        show_docker_compose_version || true
        if ! confirm "是否需要卸载现有 Docker Compose 并重新安装？"; then
            echo -e "${GREEN}选择保留现有Docker Compose环境。${NC}"
            return 1
        fi

        # 用户确认重新安装后，先执行卸载操作。
        echo -e "${YELLOW}开始卸载现有 Docker Compose...${NC}"
        uninstall_docker_compose_core
        if [ $? -ne 0 ]; then
            echo -e "${GREEN}选择保留现有Docker Compose环境。${NC}"
            return 1
        fi
        echo -e "${GREEN}现有 Docker Compose 已成功卸载，继续进行安装。${NC}"

        # 卸载后询问用户是否继续安装。
        if ! confirm "是否继续安装 Docker Compose？"; then
            echo -e "${GREEN}用户选择跳过安装。${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}未检测到 Docker Compose 环境。${NC}"
        if ! confirm "是否需要安装 Docker Compose？"; then
            echo -e "${GREEN}用户选择跳过安装。${NC}"
            return 1
        fi
    fi

    local install_method=""
    while true; do
        echo -e "${GREEN}请选择安装方式:${NC}"
        echo "1. 使用系统包管理器安装 (apt/dnf/yum/apk/pacman/zypper/opkg/pkg)"
        echo "2. 使用二进制文件安装 (离线安装)"
        read -p "请选择安装方式 (1/2): " install_method

        case "$install_method" in
            1)
                install_with_package_manager
                break
                ;;
            2)
                install_with_binary
                break
                ;;
            "")
                echo -e "${BLUE}默认选择使用系统包管理器安装${NC}"
                install_with_package_manager
                break
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入。${NC}"
                ;;
        esac
    done
}

# 卸载 Docker Compose 软件包或二进制文件，并显示移除路径。
uninstall_docker_compose_core() {
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}       Docker Compose 卸载警告${NC}"
    echo -e "${GREEN}==============================================${NC}"

    if ! check_docker_compose_installed; then
        echo -e "${RED}未检测到Docker Compose安装，无需卸载。${NC}"
        return 0
    fi

    echo -e "${GREEN}检测到系统已安装Docker Compose。${NC}"
    show_docker_compose_version || true

    if ! confirm "确定要卸载Docker Compose吗"; then
        echo -e "${GREEN}已取消卸载操作。${NC}"
        return 1
    fi

    echo -e "${GREEN}开始卸载Docker Compose...${NC}"
    local removed=0

    local manager
    manager="$(get_package_manager 2>/dev/null || true)"
    local packages=(docker-compose-plugin docker-compose-v2 docker-compose docker-compose-bin docker-cli-compose)
    local pkg
    if [ -n "$manager" ]; then
        for pkg in "${packages[@]}"; do
            if package_is_installed "$pkg"; then
                echo -e "${BLUE}使用 ${manager} 卸载软件包：$pkg${NC}"
                package_manager_remove "$pkg" || return 1
                removed=1
            fi
        done
    fi

    # 清理本脚本二进制安装的插件和兼容命令入口。
    for bin in /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose; do
        if [ -e "$bin" ] || [ -L "$bin" ]; then
            remove_path_with_report "$bin" || return 1
            removed=1
        fi
    done

    hash -r
    if check_docker_compose_installed; then
        echo -e "${YELLOW}卸载后仍检测到 Docker Compose，可能存在其他安装位置或残留插件文件。${NC}"
        show_docker_compose_version || true
        return 1
    fi

    if [ "$removed" -eq 1 ]; then
        echo -e "${GREEN}Docker Compose卸载完成！${NC}"
    else
        echo -e "${YELLOW}未找到可由当前包管理器卸载的Compose软件包。${NC}"
    fi
    return 0
}

# 安装用户指定版本的 Docker Compose。
install_specific_docker_compose() {
    # 检查系统中是否已安装 Docker Compose。
    if check_docker_compose_installed; then
        echo -e "${YELLOW}Docker Compose 已安装在系统中。${NC}"
        show_docker_compose_version || true
        if ! confirm "是否需要卸载现有 Docker Compose 并重新安装？"; then
            echo -e "${GREEN}用户选择保留现有Docker Compose环境。${NC}"
            return 1
        fi

        # 用户确认重新安装后，先执行卸载操作。
        echo -e "${YELLOW}开始卸载现有 Docker Compose...${NC}"
        uninstall_docker_compose_core
        if [ $? -ne 0 ]; then
            return 1
        fi
        echo -e "${GREEN}现有 Docker Compose 已成功卸载。${NC}"

        # 卸载后询问用户是否继续安装。
        if ! confirm "是否继续安装 Docker Compose？"; then
            echo -e "${GREEN}用户选择跳过安装。${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}未检测到 Docker Compose 环境。${NC}"
        if ! confirm "是否需要安装 Docker Compose？"; then
            echo -e "${GREEN}用户选择跳过安装。${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}开始安装 Docker Compose...${NC}"

    # 获取所有可用的 Docker Compose 版本。
    versions=($(get_all_docker_compose_versions))
    if [ ${#versions[@]} -eq 0 ]; then
        echo -e "${RED}无法获取可用版本，请检查网络。${NC}"
        return 1
    fi

    echo -e "${GREEN}可用版本列表:${NC}"
    display_versions_in_columns "${versions[@]}"

    read -p "请输入要安装的版本编号: " version_choice
    if [[ "$version_choice" =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le ${#versions[@]} ]; then
        selected_version="${versions[$((version_choice - 1))]}"
        install_with_binary "$selected_version"
    else
        echo -e "${RED}无效的选择。${NC}"
        return 1
    fi
}

# 安装用户指定版本的 Docker Engine。
install_specific_docker() {
    echo -e "${YELLOW}获取所有可用版本...${NC}"
    arch_suffix=$(get_system_arch)
    if [ $? -ne 0 ]; then
        echo -e "${RED}无法确定系统架构。${NC}"
        return 1
    fi

    versions=()
    for mirror in "${DOCKER_MIRRORS[@]}"; do
        versions+=($(get_all_docker_versions "$mirror/$arch_suffix"))
        if [ ${#versions[@]} -gt 0 ]; then
            break
        fi
    done

    if [ ${#versions[@]} -eq 0 ]; then
        echo -e "${RED}无法获取可用版本，请检查网络。${NC}"
        return 1
    fi

    echo -e "${GREEN}可用版本列表:${NC}"
    display_versions_in_columns "${versions[@]}"

    read -p "请输入要安装的版本编号: " version_choice
    if [[ "$version_choice" =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le ${#versions[@]} ]; then
        selected_version="${versions[$((version_choice - 1))]}"
        install_docker_core "$selected_version"
    else
        echo -e "${RED}无效的选择。${NC}"
        return 1
    fi
}

# 显示 Docker、Compose 和 Buildx 的简要状态。
show_brief_status() {
    if ! check_docker_installed; then
        echo -e "${YELLOW}未检测到Docker环境，跳过状态显示。${NC}"
        return
    fi

    # 获取统计信息。
    container_count=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
    image_count=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
    network_count=$(docker network ls -q 2>/dev/null | wc -l | tr -d ' ')
    volume_count=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')

    echo -e " ${NC}Docker环境状态:  ${YELLOW}容器:${container_count}  镜像:${image_count}  网络:${network_count}  卷:${volume_count}${NC}"
}

# 显示完整状态
# 显示 Docker 环境、配置及资源的详细状态。
show_full_status() {
    clear
    if ! check_docker_installed; then
        echo -e "${RED}Docker未安装${NC}"
        return
    fi

    echo -e "${GREEN}===================== Docker全局状态 =====================${NC}"
    
    # 显示 Docker 版本。
    echo -e "${YELLOW}[Docker版本信息]${NC}"
    docker --version 2>/dev/null || echo "无法获取版本"
    
    # 分别检查 Compose V2 插件和 docker-compose 兼容命令的状态。
    echo -e "\n${YELLOW}[Compose版本信息]${NC}"
    show_docker_compose_version || true
    
    echo
    
    # 显示 Docker Buildx 版本。
    echo -e "${YELLOW}[Docker Buildx版本信息]${NC}"
    docker buildx version 2>/dev/null || echo "无法获取版本"
    
    # 显示 Docker 镜像配置。
    echo -e "\n${YELLOW}[Docker镜像配置]${NC}"
    if [ -f "/etc/docker/daemon.json" ]; then
        echo "文件位置: /etc/docker/daemon.json"
        echo "配置内容:"
        cat /etc/docker/daemon.json
    else
        echo "无镜像配置文件 (/etc/docker/daemon.json 不存在)"
    fi

    # 详细列表
    echo -e "\n${YELLOW}[镜像列表]${NC}"
    docker images 2>/dev/null || echo "无镜像"
    
    echo -e "\n${YELLOW}[容器列表]${NC}"
    docker ps -a 2>/dev/null || echo "无容器"
    
    echo -e "\n${YELLOW}[卷列表]${NC}"
    docker volume ls 2>/dev/null || echo "无卷"
    
    echo -e "\n${YELLOW}[网络列表]${NC}"
    docker network ls 2>/dev/null || echo "无网络"
    
    echo -e "${GREEN}========================================================${NC}"
}

# 更新 Docker 守护进程的镜像源配置并重启服务。
update_docker_mirror() {
    echo -e "${GREEN}"
    echo "=============================================="
    echo "          更新 Docker 镜像地址"
    echo "=============================================="
    echo -e "${NC}"
    
    # 检查系统中是否已安装 Docker。
    if ! check_docker_installed; then
        echo -e "${RED}Docker未安装，请先安装Docker。${NC}"
        pause_before_return
        return 1
    fi
    
    echo -e "${YELLOW}正在更新Docker镜像地址...${NC}"
    
    # 在目录不存在时创建 /etc/docker。
    if [ ! -d "/etc/docker" ]; then
        echo -e "${YELLOW}创建 /etc/docker 目录...${NC}"
        mkdir -p /etc/docker
    fi
    
    # 下载 daemon.json 配置文件。
    echo -e "${YELLOW}下载Docker镜像配置文件...${NC}"
    cd /etc/docker
    
    # 存在原 daemon.json 时先创建备份。
    if [ -f "daemon.json" ]; then
        echo -e "${YELLOW}备份原有的daemon.json文件...${NC}"
        cp daemon.json "daemon.json.backup.$(date +%Y%m%d%H%M%S)"
        echo -e "${GREEN}原配置文件已备份。${NC}"
    fi
    
    # 下载新的 daemon.json 配置文件。
    if wget -q https://gitee.com/stu2116Edward/docker-images/raw/master/daemon.json -O daemon.json; then
        echo -e "${GREEN}Docker镜像配置文件下载成功。${NC}"
        
        # 重新加载 systemd 配置并重启 Docker。
        echo -e "${YELLOW}重新加载配置并重启Docker服务...${NC}"
        if systemctl daemon-reload && systemctl restart docker; then
            echo -e "${GREEN}Docker服务重启成功！${NC}"
            echo -e "${GREEN}镜像地址更新完成。${NC}"
            
            # 显示新的镜像配置。
            echo -e "${YELLOW}新的镜像配置如下：${NC}"
            cat /etc/docker/daemon.json
        else
            echo -e "${RED}Docker服务重启失败，请检查配置。${NC}"
            return 1
        fi
    else
        echo -e "${RED}配置文件下载失败，请检查网络连接。${NC}"
        
        # 下载失败时，询问是否创建基本的镜像配置。
        if confirm "是否创建基本的国内镜像配置？"; then
            cat > daemon.json << 'EOF'
{
  "features": {
    "time-namespaces": false
  },
  "registry-mirrors":
   [    
      "https://docker.1ms.run",
      "https://docker.kejilion.pro",
      "https://registry-1.docker.io",
      "https://registry.hub.docker.com"
   ]
}
EOF
            echo -e "${GREEN}基本镜像配置创建成功。${NC}"
            
            # 重新加载配置并重启 Docker。
            systemctl daemon-reload && systemctl restart docker
            echo -e "${GREEN}Docker服务重启成功！${NC}"
        else
            echo -e "${YELLOW}已取消操作。${NC}"
            return 1
        fi
    fi
    
    pause_before_return
    return 0
}

# 检查常见命令和插件目录中是否存在 Docker Buildx。
check_docker_buildx_installed() {
    if command -v docker-buildx &> /dev/null || \
       docker buildx version >/dev/null 2>&1 || \
       [ -f "$HOME/.docker/cli-plugins/docker-buildx" ] || \
       [ -f "/usr/local/lib/docker/cli-plugins/docker-buildx" ] || \
       [ -f "/usr/local/libexec/docker/cli-plugins/docker-buildx" ] || \
       [ -f "/usr/lib/docker/cli-plugins/docker-buildx" ] || \
       [ -f "/usr/libexec/docker/cli-plugins/docker-buildx" ]; then
        return 0
    else
        return 1
    fi
}

# 获取最新的 Docker Buildx 发布版本。
get_latest_docker_buildx_version() {
    local latest_version=$(curl -s https://api.github.com/repos/docker/buildx/releases/latest | grep 'tag_name' | cut -d\" -f4)
    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取最新版本号${NC}" >&2
        return 1
    fi
    echo "${latest_version}"
}

# 使用系统包管理器安装 Docker Buildx。
install_docker_buildx_with_package_manager() {
    echo -e "${YELLOW}尝试通过系统包管理器安装 Docker Buildx...${NC}"
    local manager
    local candidates=()
    manager="$(get_package_manager)" || {
        echo -e "${RED}未检测到支持的包管理器。${NC}"
        return 1
    }

    package_manager_update || return 1
    case "$manager" in
        apt|dnf|yum) candidates=(docker-buildx-plugin docker-buildx) ;;
        apk) candidates=(docker-cli-buildx docker-buildx) ;;
        zypper|pacman|opkg|pkg) candidates=(docker-buildx) ;;
    esac

    local candidate
    for candidate in "${candidates[@]}"; do
        if package_manager_install "$candidate"; then
            hash -r
            if docker buildx version >/dev/null 2>&1; then
                break
            fi
        fi
    done

    hash -r
    if ! docker buildx version >/dev/null 2>&1; then
        echo -e "${RED}未能通过 ${manager} 安装 Docker Buildx；请确认软件源中存在兼容的软件包。${NC}"
        return 1
    fi

    if docker buildx version >/dev/null 2>&1; then
        echo -e "${GREEN}Docker Buildx 包管理器安装成功：${NC}"
        docker buildx version
        return 0
    fi

    echo -e "${RED}安装命令执行后仍未检测到 Docker Buildx，请检查软件源及 Docker CLI 插件目录。${NC}"
    return 1
}

# 下载并安装 Docker Buildx 二进制文件。
install_docker_buildx_with_binary() {
    echo -e "${YELLOW}准备通过二进制文件安装Docker Buildx...${NC}"

    local buildx_version=""
    if [ -n "$1" ]; then
        buildx_version=$1
    else
        buildx_version=$(get_latest_docker_buildx_version)
        if [ $? -ne 0 ]; then
            echo -e "${RED}无法获取最新版本号${NC}"
            return 1
        fi
        echo -e "${YELLOW}将安装最新版本: $buildx_version${NC}"
    fi

    arch_suffix=$(get_system_arch)
    if [ $? -ne 0 ]; then
        echo -e "${RED}无法确定适合您系统的Docker Buildx版本。${NC}"
        return 1
    fi

    case "$arch_suffix" in
        "x86_64")
            buildx_arch="amd64"
            ;;
        "aarch64")
            buildx_arch="arm64"
            ;;
        "armhf")
            buildx_arch="armv7"
            ;;
        "armel")
            buildx_arch="armv6"
            ;;
        *)
            buildx_arch="$arch_suffix"
            ;;
    esac
    
    echo -e "${BLUE}检测到系统架构: $(uname -m) -> Docker Buildx架构: $buildx_arch${NC}"

    local mirror_base_urls=(
        "https://gh-proxy.com/https://github.com/docker/buildx/releases/download"
        "https://ghproxy.net/https://github.com/docker/buildx/releases/download"
        "https://github.com/docker/buildx/releases/download"
    )
    
    local binary_filename="buildx-${buildx_version}.linux-${buildx_arch}"
    local binary_url=""
    
    for base_url in "${mirror_base_urls[@]}"; do
        local test_url="$base_url/${buildx_version}/${binary_filename}"
        echo -e "${YELLOW}尝试镜像地址: $(echo "$base_url" | cut -d'/' -f3)${NC}"
        
        if timeout 10s wget --spider -q "$test_url"; then
            binary_url="$test_url"
            echo -e "${GREEN}找到可用的镜像地址: $(echo "$base_url" | cut -d'/' -f3)${NC}"
            break
        else
            echo -e "${YELLOW}镜像地址超时或不可用: $(echo "$base_url" | cut -d'/' -f3)，尝试下一个地址${NC}"
            continue
        fi
    done
    
    if [ -z "$binary_url" ]; then
        echo -e "${RED}所有镜像地址均超时或不可用，请检查网络连接或稍后重试${NC}"
        return 1
    fi

    local cli_plugins_dir="$HOME/.docker/cli-plugins"
    if [ ! -d "$cli_plugins_dir" ]; then
        echo -e "${YELLOW}创建Docker CLI插件目录: $cli_plugins_dir${NC}"
        mkdir -p "$cli_plugins_dir"
    fi

    echo -e "${YELLOW}正在下载 Docker Buildx ${buildx_version}...${NC}"
    if wget --help 2>&1 | grep -q "\-\-show-progress"; then
        if ! wget --timeout=30 --tries=3 --show-progress -O "$binary_filename" "$binary_url"; then
            echo -e "${RED}下载二进制文件失败，请检查网络连接或稍后重试${NC}"
            return 1
        fi
    else
        if ! wget --timeout=30 --tries=3 -O "$binary_filename" "$binary_url"; then
            echo -e "${RED}下载二进制文件失败，请检查网络连接或稍后重试${NC}"
            return 1
        fi
    fi

    echo -e "${YELLOW}安装Docker Buildx...${NC}"
    if ! chmod +x "$binary_filename"; then
        echo -e "${RED}设置 Docker Buildx 可执行权限失败：$binary_filename${NC}"
        return 1
    fi
    if ! mv "$binary_filename" "$cli_plugins_dir/docker-buildx"; then
        echo -e "${RED}移动 Docker Buildx 到安装目录失败：$cli_plugins_dir/docker-buildx${NC}"
        return 1
    fi
    echo -e "${GREEN}Docker Buildx 二进制安装路径：$cli_plugins_dir/docker-buildx${NC}"

    if docker buildx version >/dev/null 2>&1; then
        echo -e "${GREEN}Docker Buildx安装成功${NC}"
        docker buildx version
        return 0
    else
        echo -e "${RED}Docker Buildx安装失败，二进制文件可能不兼容当前系统${NC}"
        echo -e "${YELLOW}调试信息:${NC}"
        echo -e "系统: $(uname -s)"
        echo -e "架构: $(uname -m)"
        echo -e "Libc信息: $(ldd --version 2>/dev/null | head -n1 || echo '未知')"
        rm -f "$cli_plugins_dir/docker-buildx"
        return 1
    fi
}

# 卸载 Docker Buildx 软件包或二进制文件，并显示移除路径。
uninstall_docker_buildx() {
    echo -e "${GREEN}"
    echo "=============================================="
    echo "       Docker Buildx 卸载警告"
    echo "=============================================="
    echo -e "${NC}此操作将删除Docker Buildx可执行文件"
    echo -e "${GREEN}=============================================="
    echo -e "${NC}"

    if ! check_docker_buildx_installed; then
        echo -e "${RED}未检测到Docker Buildx安装，无需卸载。${NC}"
        return 1
    fi

    echo -e "${GREEN}检测到系统已安装Docker Buildx。${NC}"
    docker buildx version 2>/dev/null || true

    if ! confirm "确定要卸载Docker Buildx吗"; then
        echo -e "${GREEN}已取消卸载操作。${NC}"
        return 1
    fi

    echo -e "${GREEN}开始卸载Docker Buildx...${NC}"
    local removed=0

    local plugin_paths=(
        "$HOME/.docker/cli-plugins/docker-buildx"
        "/usr/local/lib/docker/cli-plugins/docker-buildx"
        "/usr/local/libexec/docker/cli-plugins/docker-buildx"
        "/usr/lib/docker/cli-plugins/docker-buildx"
        "/usr/libexec/docker/cli-plugins/docker-buildx"
    )

    for file in "${plugin_paths[@]}"; do
        if [ -e "$file" ] || [ -L "$file" ]; then
            remove_path_with_report "$file" || return 1
            removed=1
        fi
    done

    local manager
    manager="$(get_package_manager 2>/dev/null || true)"
    local packages=(docker-buildx-plugin docker-buildx docker-cli-buildx)
    local package
    if [ -n "$manager" ]; then
        for package in "${packages[@]}"; do
            if package_is_installed "$package"; then
                package_manager_remove "$package" || return 1
                removed=1
            fi
        done
    fi

    hash -r

    if check_docker_buildx_installed; then
        echo -e "${YELLOW}卸载后仍检测到 Docker Buildx，可能存在残留插件文件或系统目录安装。${NC}"
        docker buildx version 2>/dev/null || true
        return 1
    fi

    if [ "$removed" -eq 1 ]; then
        echo -e "${GREEN}Docker Buildx卸载完成!${NC}"
    else
        echo -e "${YELLOW}未找到可由当前包管理器卸载的 Docker Buildx。${NC}"
    fi
    return 0
}

# 执行 Docker Buildx 安装主流程并处理安装方式选择。
install_docker_buildx_core() {
    # 检查系统中是否已安装 Docker Buildx。
    if check_docker_buildx_installed; then
        echo -e "${YELLOW}Docker Buildx 已安装在系统中。${NC}"
        docker buildx version
        if ! confirm "是否需要卸载现有 Docker Buildx 并重新安装？"; then
            echo -e "${GREEN}选择保留现有Docker Buildx环境。${NC}"
            return 1
        fi

        # 用户确认重新安装后，先执行卸载操作。
        echo -e "${YELLOW}开始卸载现有 Docker Buildx...${NC}"
        uninstall_docker_buildx
        if [ $? -ne 0 ]; then
            echo -e "${GREEN}选择保留现有Docker Buildx环境。${NC}"
            return 1
        fi
        echo -e "${GREEN}现有 Docker Buildx 已成功卸载，继续进行安装。${NC}"

        # 卸载后询问用户是否继续安装。
        if ! confirm "是否继续安装 Docker Buildx？"; then
            echo -e "${GREEN}用户选择跳过安装。${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}未检测到 Docker Buildx 环境。${NC}"
        if ! confirm "是否需要安装 Docker Buildx？"; then
            echo -e "${GREEN}用户选择跳过安装。${NC}"
            return 1
        fi
    fi

    local install_method=""
    while true; do
        echo -e "${GREEN}请选择安装方式:${NC}"
        echo "1. 使用系统包管理器安装 (apt/dnf/yum/apk/pacman/zypper/opkg/pkg)"
        echo "2. 使用二进制文件安装 (离线安装)"
        read -p "请选择安装方式 (1/2，默认1): " install_method

        case "$install_method" in
            1)
                install_docker_buildx_with_package_manager
                break
                ;;
            2)
                install_docker_buildx_with_binary
                break
                ;;
            "")
                echo -e "${BLUE}默认选择使用系统包管理器安装${NC}"
                install_docker_buildx_with_package_manager
                break
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入。${NC}"
                ;;
        esac
    done
}

# 提供 Docker 容器的交互式管理操作。
docker_container_manage() {
    while true; do
        clear
        echo -e "${GREEN}Docker容器列表:${NC}"
        docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo "容器操作"
        echo "------------------------"
        echo "1. 创建新的容器"
        echo "2. 启动指定容器         6. 启动所有容器"
        echo "3. 停止指定容器         7. 停止所有容器"
        echo "4. 删除指定容器         8. 删除所有容器"
        echo "5. 重启指定容器         9. 重启所有容器"
        echo "------------------------"
        echo "11. 进入指定容器        12. 查看容器日志"
        echo "13. 查看容器网络        14. 查看容器占用"
        echo "------------------------"
        echo "0. 返回上一级菜单"
        echo "------------------------"
        read -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1)
                read -p "请输入docker run命令: " run_cmd
                eval "$run_cmd"
                pause_before_return
                ;;
            2)
                read -p "请输入容器名/ID（多个用空格分隔）: " names
                docker start $names
                pause_before_return
                ;;
            3)
                read -p "请输入容器名/ID（多个用空格分隔）: " names
                docker stop $names
                pause_before_return
                ;;
            4)
                read -p "请输入容器名/ID（多个用空格分隔）: " names
                docker rm -f $names
                pause_before_return
                ;;
            5)
                read -p "请输入容器名/ID（多个用空格分隔）: " names
                docker restart $names
                pause_before_return
                ;;
            6)
                docker start $(docker ps -a -q)
                pause_before_return
                ;;
            7)
                docker stop $(docker ps -q)
                pause_before_return
                ;;
            8)
                read -p "确定删除所有容器吗？(Y/N): " choice
                [[ "$choice" =~ [Yy] ]] && docker rm -f $(docker ps -a -q)
                pause_before_return
                ;;
            9)
                docker restart $(docker ps -q)
                pause_before_return
                ;;
            11)
                read -p "请输入容器名/ID: " name
                docker exec -it $name /bin/sh
                pause_before_return
                ;;
            12)
                read -p "请输入容器名/ID: " name
                # 兼容日志查看，支持分页
                if command -v less &>/dev/null; then
                    docker logs $name | less
                else
                    docker logs $name
                fi
                pause_before_return
                ;;
            13)
                # 参考 kejilion.sh 的实现，显示所有容器的网络和 IP。
                echo ""
                container_ids=$(docker ps -q)
                echo "------------------------------------------------------------"
                printf "%-25s %-25s %-25s\n" "容器名称" "网络名称" "IP地址"
                for container_id in $container_ids; do
                    docker inspect --format '{{.Name}} {{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{end}}' "$container_id" | \
                    awk '{cname=$1; for(i=2;i<=NF;i+=2) printf "%-25s %-25s %-25s\n", cname, $(i), $(i+1)}'
                done
                echo "------------------------------------------------------------"
                pause_before_return
                ;;
            14)
                # 参考 kejilion.sh 的实现，显示容器资源占用情况。
                docker stats --no-stream
                pause_before_return
                ;;
            0)
                break
                ;;
            *)
                echo "无效的选项，请重新输入。"
                pause_before_return
                ;;
        esac
    done
}

# 提供 Docker 镜像的交互式管理操作。
docker_image_manage() {
    while true; do
        clear
        echo -e "${GREEN}Docker镜像列表:${NC}"
        docker image ls
        echo ""
        echo "镜像操作"
        echo "------------------------"
        echo "1. 拉取/更新指定镜像    3. 删除所有镜像"
        echo "2. 删除指定镜像"
        echo "------------------------"
        echo "0. 返回上一级菜单"
        echo "------------------------"
        read -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1)
                read -p "请输入镜像名（多个用空格分隔）: " names
                for name in $names; do
                    docker pull $name
                done
                pause_before_return
                ;;
            2)
                read -p "请输入镜像名（多个用空格分隔）: " names
                for name in $names; do
                    docker rmi -f $name
                done
                pause_before_return
                ;;
            3)
                read -p "确定删除所有镜像吗？(Y/N): " choice
                [[ "$choice" =~ [Yy] ]] && docker rmi -f $(docker images -q)
                pause_before_return
                ;;
            0)
                break
                ;;
            *)
                echo "无效的选项，请重新输入。"
                pause_before_return
                ;;
        esac
    done
}

# 提供 Docker 网络的交互式管理操作。
docker_network_manage() {
    while true; do
        clear
        echo -e "${GREEN}Docker网络列表:${NC}"
        docker network ls
        echo ""
        # 显示所有容器的网络和 IP 地址。
        echo "------------------------------------------------------------"
        printf "%-25s %-20s %-20s\n" "容器名称" "网络名称" "IP地址"
        for cid in $(docker ps -q); do
            cname=$(docker inspect --format '{{.Name}}' $cid)
            docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%-25s %-20s %-20s\n" "'"$cname"'" $k $v.IPAddress}}{{end}}' $cid
        done
        echo "------------------------------------------------------------"
        echo "1. 创建网络"
        echo "2. 加入网络"
        echo "3. 退出网络"
        echo "4. 删除网络"
        echo "0. 返回上一级菜单"
        echo "------------------------"
        read -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1)
                read -p "设置新网络名: " netname
                docker network create $netname
                pause_before_return
                ;;
            2)
                read -p "加入网络名: " netname
                read -p "容器名/ID（多个用空格分隔）: " names
                for n in $names; do
                    docker network connect $netname $n
                done
                pause_before_return
                ;;
            3)
                read -p "退出网络名: " netname
                read -p "容器名/ID（多个用空格分隔）: " names
                for n in $names; do
                    docker network disconnect $netname $n
                done
                pause_before_return
                ;;
            4)
                read -p "请输入要删除的网络名: " netname
                docker network rm $netname
                pause_before_return
                ;;
            0)
                break
                ;;
            *)
                echo "无效的选项，请重新输入。"
                pause_before_return
                ;;
        esac
    done
}

# 提供 Docker 卷的交互式管理操作。
docker_volume_manage() {
    while true; do
        clear
        echo -e "${GREEN}Docker卷列表:${NC}"
        docker volume ls
        echo ""
        echo "卷操作"
        echo "------------------------"
        echo "1. 创建新卷"
        echo "2. 删除指定卷"
        echo "3. 删除所有卷"
        echo "------------------------"
        echo "0. 返回上一级菜单"
        echo "------------------------"
        read -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1)
                read -p "设置新卷名: " vname
                docker volume create $vname
                pause_before_return
                ;;
            2)
                read -p "输入删除卷名（多个用空格分隔）: " vnames
                for v in $vnames; do
                    docker volume rm $v
                done
                pause_before_return
                ;;
            3)
                read -p "确定删除所有卷吗？(Y/N): " choice
                if [[ "$choice" =~ [Yy] ]]; then
                    docker volume rm $(docker volume ls -q)
                fi
                pause_before_return
                ;;
            0)
                break
                ;;
            *)
                echo "无效的选项，请重新输入。"
                pause_before_return
                ;;
        esac
    done
}

# 显示主菜单及各项 Docker 管理功能。
show_menu() {
    clear
    echo -e "${GREEN}========================================================${NC}"
    echo -e "${ORANGE}           	   Docker 管理工具箱${NC}"
    echo -e "${GREEN}========================================================${NC}"
    show_brief_status
    echo -e "${GREEN} 1. 安装 Docker${NC}"
    echo -e "${GREEN} 2. 卸载 Docker${NC}"
    echo -e "${GREEN} 3. 安装指定版本 Docker${NC}"
    echo -e "${GREEN} 4. 安装 Docker Compose${NC}"
    echo -e "${GREEN} 5. 卸载 Docker Compose${NC}"
    echo -e "${GREEN} 6. 安装指定版本 Docker Compose${NC}"
    echo -e "${GREEN} 7. 查看Docker全局状态 ★${NC}"
    echo -e "${GREEN} 8. Docker容器管理${NC}"
    echo -e "${GREEN} 9. Docker镜像管理${NC}"
    echo -e "${GREEN}10. Docker网络管理${NC}"
    echo -e "${GREEN}11. Docker卷管理${NC}"
    echo -e "${GREEN}12. 更新Docker镜像地址${NC}"
    echo -e "${GREEN}13. 安装 Docker Buildx${NC}"
    echo -e "${GREEN}14. 卸载 Docker Buildx${NC}"
    echo -e "${GREEN}15. 完整卸载并清理 Docker 环境（含数据）${NC}"
    echo -e "${GREEN}--------------------------------------------------------${NC}"
    echo -e "${GREEN}00. 获取最新脚本并重新运行${NC}"
    echo -e "${GREEN} 0. 退出脚本${NC}"
    echo -e "${GREEN}========================================================${NC}"
    echo
}

# 读取菜单选择并调度对应的 Docker 管理功能。
main() {
    while true; do
        show_menu
        stty erase ^H
        read -p "请输入选项编号 (0-15|00): " choice
        case "$choice" in
            1)  install_docker_core; pause_before_return ;;
            2)  uninstall_docker_core; pause_before_return ;;
            3)  install_specific_docker; pause_before_return ;;
            4)  install_docker_compose_core; pause_before_return ;;
            5)  uninstall_docker_compose_core; pause_before_return ;;
            6)  install_specific_docker_compose; pause_before_return ;;
            7)  clear; show_full_status; pause_before_return ;;
            8)  docker_container_manage ;;
            9)  docker_image_manage ;;
            10) docker_network_manage ;;
            11) docker_volume_manage ;;
            12) update_docker_mirror ;;
            13) install_docker_buildx_core; pause_before_return ;;
            14) uninstall_docker_buildx; pause_before_return ;;
            15) docker_clean_all; pause_before_return ;;
            00)
                echo -e "${YELLOW}正在拉取最新脚本...${NC}"
                for url in \
                  "https://gitee.com/stu2116Edward/docker-tools/raw/master/docker_tools.sh" \
                  "https://raw.githubusercontent.com/stu2116Edward/Public-study-notes/refs/heads/main/Docker%20Notes/Docker_Shell/docker_tools.sh"
                do
                    if curl -sS -O "$url" && [[ -s docker_tools.sh ]]; then
                        chmod +x docker_tools.sh
                        echo -e "${GREEN}获取成功，即将重启脚本...${NC}"
                        exec ./docker_tools.sh
                    fi
                done
                echo -e "${RED}所有源均不可用，请检查网络！${NC}"
                pause_before_return
                ;;
            0)
                echo -e "${GREEN}已退出脚本。${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选项，请重新输入!${NC}"
                pause_before_return
                ;;
        esac
    done
}

main
