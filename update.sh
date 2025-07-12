#!/bin/sh

NZ_BASE_PATH="/opt/nezha"
NZ_AGENT_PATH="${NZ_BASE_PATH}/agent"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() {
    printf "${red}%s${plain}\n" "$*" >&2
}

success() {
    printf "${green}%s${plain}\n" "$*"
}

info() {
    printf "${yellow}%s${plain}\n" "$*"
}

sudo() {
    myEUID=$(id -ru)
    if [ "$myEUID" -ne 0 ]; then
        if command -v sudo > /dev/null 2>&1; then
            command sudo "$@"
        else
            err "ERROR: sudo is not installed on the system, the action cannot be proceeded."
            exit 1
        fi
    else
        "$@"
    fi
}

deps_check() {
    local deps="curl unzip grep"
    local _err=0
    local missing=""

    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            _err=1
            missing="${missing} $dep"
        fi
    done

    if [ "$_err" -ne 0 ]; then
        err "Missing dependencies:$missing. Please install them and try again."
        exit 1
    fi
}

geo_check() {
    api_list="https://blog.cloudflare.com/cdn-cgi/trace https://developers.cloudflare.com/cdn-cgi/trace"
    ua="Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0"
    set -- "$api_list"
    for url in $api_list; do
        text="$(curl -A "$ua" -m 10 -s "$url")"
        endpoint="$(echo "$text" | sed -n 's/.*h=\([^ ]*\).*/\1/p')"
        if echo "$text" | grep -qw 'CN'; then
            isCN=true
            break
        elif echo "$url" | grep -q "$endpoint"; then
            break
        fi
    done
}

env_check() {
    mach=$(uname -m)
    case "$mach" in
        amd64|x86_64)
            os_arch="amd64"
            ;;
        i386|i686)
            os_arch="386"
            ;;
        aarch64|arm64)
            os_arch="arm64"
            ;;
        *arm*)
            os_arch="arm"
            ;;
        s390x)
            os_arch="s390x"
            ;;
        riscv64)
            os_arch="riscv64"
            ;;
        mips)
            os_arch="mips"
            ;;
        mipsel|mipsle)
            os_arch="mipsle"
            ;;
        *)
            err "Unknown architecture: $uname"
            exit 1
            ;;
    esac

    system=$(uname)
    case "$system" in
        *Linux*)
            os="linux"
            ;;
        *Darwin*)
            os="darwin"
            ;;
        *FreeBSD*)
            os="freebsd"
            ;;
        *)
            err "Unknown architecture: $system"
            exit 1
            ;;
    esac
}

check_agent_exists() {
    if [ ! -f "$NZ_AGENT_PATH/nezha-agent" ]; then
        err "nezha-agent not found at $NZ_AGENT_PATH/nezha-agent"
        err "Please install nezha-agent first"
        exit 1
    fi
}

get_current_version() {
    current_version=$("$NZ_AGENT_PATH/nezha-agent" -v 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n 1)
    if [ -z "$current_version" ]; then
        current_version="unknown"
    fi
}

stop_service() {
    info "Stopping nezha-agent service..."

    # 查找配置文件并停止服务
    config_found=false
    if [ -d "$NZ_AGENT_PATH" ]; then
        for config_file in "$NZ_AGENT_PATH"/config*.yml; do
            if [ -f "$config_file" ]; then
                config_found=true
                info "Stopping service with config: $config_file"
                sudo "$NZ_AGENT_PATH/nezha-agent" service -c "$config_file" stop >/dev/null 2>&1
            fi
        done
    fi

    if [ "$config_found" = false ]; then
        err "No config file found in $NZ_AGENT_PATH"
        exit 1
    fi

    # 等待服务完全停止
    sleep 2
    success "nezha-agent service stopped"
}

start_service() {
    info "Starting nezha-agent service..."

    # 查找配置文件并启动服务
    for config_file in "$NZ_AGENT_PATH"/config*.yml; do
        if [ -f "$config_file" ]; then
            info "Starting service with config: $config_file"
            sudo "$NZ_AGENT_PATH/nezha-agent" service -c "$config_file" start >/dev/null 2>&1
        fi
    done

    # 等待服务启动
    sleep 2
    success "nezha-agent service started"
}

download_latest() {
    info "Downloading latest nezha-agent..."

    if [ -z "$CN" ]; then
        NZ_AGENT_URL="https://${GITHUB_URL}/nezhahq/agent/releases/latest/download/nezha-agent_${os}_${os_arch}.zip"
    else
        _version=$(curl -m 10 -sL "https://gitee.com/api/v5/repos/naibahq/agent/releases/latest" | awk -F '"' '{for(i=1;i<=NF;i++){if($i=="tag_name"){print $(i+2)}}}')
        NZ_AGENT_URL="https://${GITHUB_URL}/naibahq/agent/releases/download/${_version}/nezha-agent_${os}_${os_arch}.zip"
    fi

    if command -v wget >/dev/null 2>&1; then
        _cmd="wget --timeout=60 -O /tmp/nezha-agent_${os}_${os_arch}.zip \"$NZ_AGENT_URL\" >/dev/null 2>&1"
    elif command -v curl >/dev/null 2>&1; then
        _cmd="curl --max-time 60 -fsSL \"$NZ_AGENT_URL\" -o /tmp/nezha-agent_${os}_${os_arch}.zip >/dev/null 2>&1"
    fi

    if ! eval "$_cmd"; then
        err "Download nezha-agent release failed, check your network connectivity"
        exit 1
    fi

    success "Download completed"
}

backup_current() {
    info "Creating backup of current binary..."
    sudo cp "$NZ_AGENT_PATH/nezha-agent" "$NZ_AGENT_PATH/nezha-agent.backup.$(date +%Y%m%d_%H%M%S)"
    success "Backup created"
}

update_binary() {
    info "Updating nezha-agent binary..."

    # 创建临时目录
    temp_dir="/tmp/nezha-agent-update"
    mkdir -p "$temp_dir"

    # 解压新版本
    if ! unzip -qo "/tmp/nezha-agent_${os}_${os_arch}.zip" -d "$temp_dir"; then
        err "Failed to extract nezha-agent"
        rm -rf "$temp_dir"
        exit 1
    fi

    # 替换二进制文件
    if ! sudo cp "$temp_dir/nezha-agent" "$NZ_AGENT_PATH/nezha-agent"; then
        err "Failed to update binary"
        rm -rf "$temp_dir"
        exit 1
    fi

    # 设置执行权限
    sudo chmod +x "$NZ_AGENT_PATH/nezha-agent"

    # 清理临时文件
    rm -rf "$temp_dir"
    rm -f "/tmp/nezha-agent_${os}_${os_arch}.zip"

    success "Binary updated successfully"
}

get_new_version() {
    new_version=$("$NZ_AGENT_PATH/nezha-agent" -v 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n 1)
    if [ -z "$new_version" ]; then
        new_version="unknown"
    fi
}

init() {
    deps_check
    env_check

    ## China_IP
    if [ -z "$CN" ]; then
        geo_check
        if [ -n "$isCN" ]; then
            CN=true
        fi
    fi

    if [ -z "$CN" ]; then
        GITHUB_URL="github.com"
    else
        GITHUB_URL="gitee.com"
    fi
}

update() {
    info "========================================="
    info "       nezha-agent Update Script        "
    info "========================================="

    check_agent_exists
    get_current_version

    info "Current version: $current_version"
    info "Updating to latest version..."

    download_latest
    backup_current
    stop_service
    update_binary
    start_service

    get_new_version

    info "========================================="
    success "Update completed successfully!"
    info "Previous version: $current_version"
    info "Current version: $new_version"
    info "========================================="
}

# 主执行逻辑
init
update
