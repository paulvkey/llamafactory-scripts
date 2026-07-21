#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

readonly INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/llamafactory"
readonly BIN_DIR="$HOME/.local/bin"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/llamafactory-scripts"
readonly CONFIG_FILE="$CONFIG_DIR/config"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/llamafactory"

INSTALL_MODE=''
SOURCE_DIR="$HOME/LlamaFactory"
CONDA_ENV_NAME='llamafactory'
CONDA_EXE=''

load_config() {
  local key value
  [[ -r "$CONFIG_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      INSTALL_MODE) INSTALL_MODE=$value ;;
      SOURCE_DIR) SOURCE_DIR=$value ;;
      CONDA_ENV_NAME) CONDA_ENV_NAME=$value ;;
      CONDA_EXE) CONDA_EXE=$value ;;
    esac
  done <"$CONFIG_FILE"
}

remove_managed_source() {
  local path=$1
  case "$path" in
    "$HOME/LlamaFactory"|"$INSTALL_ROOT/source") rm -rf -- "$path" ;;
    *) die "拒绝删除异常源码路径：$path" ;;
  esac
}

remove_managed_command() {
  local path=$1 expected="$INSTALL_ROOT/runtime/llamafactory-webui"
  if [[ -L "$path" && $(readlink -- "$path") == "$expected" ]]; then
    rm -f -- "$path"
  elif [[ -e "$path" || -L "$path" ]]; then
    warn "保留不属于本脚本的同名文件：$path"
  fi
}

remove_managed_tree() {
  local path=$1
  case "$path" in
    */llamafactory|*/llamafactory-scripts) rm -rf -- "$path" ;;
    *) die "拒绝删除异常路径：$path" ;;
  esac
}

main() {
  [[ ${EUID:-$(id -u)} -ne 0 ]] || die '请勿使用 root 或 sudo 运行。'
  load_config

  step '卸载 LlamaFactory 用户级安装'
  confirm '停止 WebUI 并删除命令、源码、配置和运行日志？' N || { warn '已取消卸载。'; return; }

  if [[ -x "$INSTALL_ROOT/runtime/llamafactory-webui" ]]; then
    "$INSTALL_ROOT/runtime/llamafactory-webui" stop || true
  fi

  remove_managed_command "$BIN_DIR/llamafactory-webui"
  remove_managed_command "$BIN_DIR/llamafactory-webui-start"
  remove_managed_command "$BIN_DIR/llamafactory-webui-stop"
  remove_managed_source "$SOURCE_DIR"
  remove_managed_tree "$INSTALL_ROOT"
  remove_managed_tree "$CONFIG_DIR"
  remove_managed_tree "$STATE_DIR"
  success '命令、源码、配置和运行日志已删除。'

  if [[ "$INSTALL_MODE" == conda && -n "$CONDA_EXE" && -x "$CONDA_EXE" ]]; then
    if confirm "是否同时删除 Conda 环境 $CONDA_ENV_NAME？" N; then
      "$CONDA_EXE" env remove -y -n "$CONDA_ENV_NAME"
      success "Conda 环境 $CONDA_ENV_NAME 已删除。"
    else
      info "已保留 Conda 环境 $CONDA_ENV_NAME。"
    fi
  fi
  info '脚本自动安装的 Miniconda 不会被删除，因为其中可能已有其他环境。'
}

main "$@"
