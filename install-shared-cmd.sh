#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

readonly PUBLIC_BIN_DIR='/usr/local/bin'

trap 'error "安装失败（第 ${LINENO} 行）。请检查上方输出。"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

find_conda() {
  local candidate bashrc_conda=''
  if command -v conda >/dev/null 2>&1; then
    command -v conda
    return
  fi
  if [[ -r "$HOME/.bashrc" ]]; then
    bashrc_conda=$(awk -F"'" '/^__conda_setup=.*shell\.bash/ { print $2; exit }' "$HOME/.bashrc")
  fi
  for candidate in \
    "$bashrc_conda" \
    '/data1/user/miniconda3/bin/conda' \
    "$HOME/miniconda3/bin/conda" \
    "$HOME/anaconda3/bin/conda" \
    "$HOME/.local/miniconda3/bin/conda"; do
    [[ -n "$candidate" ]] || continue
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return; }
  done
  return 1
}

validate_package() {
  local package=$1
  [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9_.:@=+-]*$ ]] || die "Conda 包名包含不支持的字符：$package"
}

validate_channel() {
  local channel=$1
  [[ "$channel" =~ ^[A-Za-z0-9][A-Za-z0-9_./:@+-]*$ ]] || die "Conda channel 包含不支持的字符：$channel"
}

validate_command_name() {
  local label=$1 command_name=$2
  [[ "$command_name" =~ ^[A-Za-z0-9._+-]+$ ]] || die "$label 不是有效的命令名：$command_name"
  [[ "$command_name" != '.' && "$command_name" != '..' ]] || die "$label 无效：$command_name"
}

show_parent_permissions() {
  local conda_base=$1
  if command -v namei >/dev/null 2>&1; then
    namei -l "$conda_base/bin" || true
  else
    ls -ld -- "$conda_base" "$conda_base/bin"
  fi
}

confirm_shared_permissions() {
  local conda_base=$1 parent
  local -a parents=()

  parent=$(dirname -- "$conda_base")
  while [[ "$parent" != / && -n "$parent" ]]; do
    parents+=("$parent")
    parent=$(dirname -- "$parent")
  done

  info '将进行以下权限调整：'
  printf '  Conda base 递归增加所有用户读取/执行权限：%s\n' "$conda_base"
  for parent in "${parents[@]}"; do
    printf '  父目录增加其他用户穿越权限（o+x）：%s\n' "$parent"
  done
  warn '不会授予其他用户写权限，但他们将能读取 Conda base 中的文件。'
  confirm '确认调整以上权限？' N || die '未授权公共读取权限，无法保证所有用户可运行该命令。'
}

grant_shared_permissions() {
  local conda_base=$1 parent
  local -a parents=()

  parent=$(dirname -- "$conda_base")
  while [[ "$parent" != / && -n "$parent" ]]; do
    parents+=("$parent")
    parent=$(dirname -- "$parent")
  done

  sudo chmod -R a+rX -- "$conda_base"
  for parent in "${parents[@]}"; do
    sudo chmod o+x -- "$parent"
  done
}

publish_command() {
  local source_command=$1 public_name=$2
  local public_path="$PUBLIC_BIN_DIR/$public_name" current_target='' backup_path

  if [[ -L "$public_path" ]]; then
    current_target=$(readlink -- "$public_path")
  fi
  if [[ "$current_target" == "$source_command" ]]; then
    info "公共命令已经指向目标：$public_path"
    return
  fi

  if [[ -e "$public_path" || -L "$public_path" ]]; then
    warn "公共命令已经存在：$public_path"
    ls -l -- "$public_path"
    confirm '是否备份现有命令并替换？' N || die '已保留现有公共命令。'
    backup_path="${public_path}.backup.$(date +%Y%m%d%H%M%S)"
    sudo mv -- "$public_path" "$backup_path"
    info "原命令已备份到：$backup_path"
  fi

  sudo ln -s -- "$source_command" "$public_path"
  success "已发布公共命令：$public_path -> $source_command"
}

main() {
  local conda_exe conda_base package channel env_command public_name source_command
  local verify_version=0

  [[ ${EUID:-$(id -u)} -ne 0 ]] || die '请使用具有 sudo 权限的普通管理员账号运行，不要直接使用 root。'
  require_command sudo
  require_command awk

  step '检查管理员权限与 Conda base'
  sudo -v
  conda_exe=$(find_conda) || die '未找到 Conda。请先初始化 Conda，或确认 /data1/user/miniconda3/bin/conda 存在。'
  conda_base=$("$conda_exe" info --base)
  [[ "$conda_base" == /* && "$conda_base" != / ]] || die "Conda base 路径异常：$conda_base"
  [[ -x "$conda_base/bin/conda" ]] && conda_exe="$conda_base/bin/conda"
  success "Conda：$conda_exe"
  info "Base 环境：$conda_base"

  step '设置要安装的公共命令'
  package=$(ask 'Conda 包名' nvitop)
  channel=$(ask 'Conda channel' conda-forge)
  env_command=$(ask '安装后在 base/bin 中生成的命令名' nvitop)
  public_name=$(ask '所有用户执行的公共命令名' "$env_command")
  validate_package "$package"
  validate_channel "$channel"
  validate_command_name '环境内命令名' "$env_command"
  validate_command_name '公共命令名' "$public_name"
  if confirm '是否使用 --version 参数验证该命令？' Y; then
    verify_version=1
  fi

  printf '\n  Conda base：%s\n  包：%s\n  Channel：%s\n  环境内命令：%s/bin/%s\n  公共命令：%s/%s\n' \
    "$conda_base" "$package" "$channel" "$conda_base" "$env_command" "$PUBLIC_BIN_DIR" "$public_name"
  confirm '确认安装并发布给所有用户？' Y || { warn '已取消。'; return; }
  confirm_shared_permissions "$conda_base"

  step "安装 $package 到 Conda base"
  "$conda_exe" install --name base --channel "$channel" --yes "$package"
  source_command="$conda_base/bin/$env_command"
  [[ -x "$source_command" ]] || die "安装完成但未找到可执行命令：$source_command"
  if (( verify_version )); then
    "$source_command" --version || warn '命令的 --version 验证失败，将继续发布。'
  fi

  step '配置所有用户的读取和执行权限'
  show_parent_permissions "$conda_base"
  grant_shared_permissions "$conda_base"

  step '发布到系统公共 PATH'
  [[ -d "$PUBLIC_BIN_DIR" ]] || sudo install -d -m 0755 "$PUBLIC_BIN_DIR"
  publish_command "$source_command" "$public_name"

  step '验证公共命令'
  if (( verify_version )); then
    "$PUBLIC_BIN_DIR/$public_name" --version || warn '公共命令的 --version 验证失败，请手动检查。'
  else
    info '已按管理员选择跳过 --version 验证。'
  fi
  success '公共命令安装完成。'
  info "所有用户现在可以直接执行：$public_name"
  info "管理员以后可再次运行本脚本，输入其他包名和命令名。"
}

main "$@"
