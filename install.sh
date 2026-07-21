#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

readonly CONDA_ENV_NAME='llamafactory'
readonly INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/llamafactory"
readonly SOURCE_DIR="$INSTALL_ROOT/source"
readonly RUNTIME_DIR="$INSTALL_ROOT/runtime"
readonly BIN_DIR="$HOME/.local/bin"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/llamafactory-scripts"
readonly CONFIG_FILE="$CONFIG_DIR/config"
readonly REPOSITORY_URL='https://github.com/hiyouga/LlamaFactory.git'

trap 'error "安装失败（第 ${LINENO} 行）。请检查上方输出。"' ERR

require_ubuntu() {
  [[ ${EUID:-$(id -u)} -ne 0 ]] || die '请勿使用 root 或 sudo 运行；本脚本只为当前用户安装。'
  [[ -r /etc/os-release ]] || die '无法识别操作系统；本脚本仅支持 Ubuntu。'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == ubuntu || ${ID_LIKE:-} == *ubuntu* ]] || die "检测到 ${PRETTY_NAME:-未知系统}；本脚本仅支持 Ubuntu。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1。请先让管理员安装它。"
}

find_conda() {
  local candidate bashrc_conda=''
  for candidate in "${CONDA_EXE:-}" "$(type -P conda 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s\n' "$candidate"; return; }
  done
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

activate_conda_environment() {
  local conda_exe=$1 env_name=$2 conda_base conda_sh
  conda_base=$("$conda_exe" info --base)
  conda_sh="$conda_base/etc/profile.d/conda.sh"
  [[ -r "$conda_sh" ]] || die "找不到 Conda 初始化脚本：$conda_sh"

  # Conda 的 shell 脚本在部分版本中会读取未定义变量，加载时临时关闭 nounset。
  set +u
  # shellcheck disable=SC1090
  source "$conda_sh"
  conda activate "$env_name"
  set -u

  [[ -n ${CONDA_PREFIX:-} && -x "$CONDA_PREFIX/bin/python" ]] \
    || die "Conda 环境激活失败：$env_name"
  success "当前安装进程已激活 Conda 环境：$env_name（$CONDA_PREFIX）"
}

check_conda_setup() {
  local conda_exe envs_config pkgs_config answer_default='N'
  local bashrc_configured=0
  local current_user="${USER:-$(id -un)}"
  local expected_envs="/data1/conda_envs/users/$current_user"
  local expected_pkgs="/data1/conda_pkgs/users/$current_user"

  step '检查 Conda 与用户目录配置'
  if conda_exe=$(find_conda); then
    success "检测到 Conda：$conda_exe"
    envs_config=$("$conda_exe" config --show envs_dirs 2>/dev/null || true)
    pkgs_config=$("$conda_exe" config --show pkgs_dirs 2>/dev/null || true)
    [[ -n "$envs_config" ]] && printf '%s\n' "$envs_config"
    [[ -n "$pkgs_config" ]] && printf '%s\n' "$pkgs_config"
    if [[ -r "$HOME/.bashrc" ]] \
      && grep -Fxq '# >>> conda initialize >>>' "$HOME/.bashrc" \
      && grep -Fq "$conda_exe" "$HOME/.bashrc"; then
      bashrc_configured=1
    fi

    if [[ "$envs_config" == *"$expected_envs"* \
      && "$pkgs_config" == *"$expected_pkgs"* \
      && "$bashrc_configured" == 1 ]]; then
      success 'Bash 初始化、共享环境目录和包缓存目录已经配置。'
    else
      warn 'Conda 的 Bash 初始化或推荐共享目录尚未完整配置。'
      answer_default='Y'
    fi
    if confirm '是否现在执行 setup-conda.sh？' "$answer_default"; then
      LLAMAFACTORY_INSTALLER_CALL=1 bash "$SCRIPT_DIR/setup-conda.sh"
    fi
  else
    warn '当前 PATH、~/.bashrc 和常见安装路径中均未检测到 Conda。'
    if confirm '是否手动指定 Conda 路径并执行 setup-conda.sh？' N; then
      LLAMAFACTORY_INSTALLER_CALL=1 bash "$SCRIPT_DIR/setup-conda.sh"
    else
      info '已跳过 Conda 目录配置；后续仍可选择自动安装 Miniconda。'
    fi
  fi

  if conda_exe=$(find_conda); then
    info "后续安装将使用检测到的 Conda：$conda_exe"
  fi
}

install_miniconda() {
  local arch installer_url installer_file miniconda_dir="$HOME/.local/miniconda3"
  case $(uname -m) in
    x86_64) arch='x86_64' ;;
    aarch64|arm64) arch='aarch64' ;;
    *) die "Miniconda 自动安装不支持此架构：$(uname -m)" ;;
  esac
  installer_url="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${arch}.sh"
  installer_file=$(mktemp "${TMPDIR:-/tmp}/miniconda.XXXXXX.sh")
  info "下载 Miniconda：$installer_url" >&2
  curl -fL --retry 3 --output "$installer_file" "$installer_url"
  bash "$installer_file" -b -p "$miniconda_dir" >&2
  rm -f -- "$installer_file"
  printf '%s\n' "$miniconda_dir/bin/conda"
}

python_is_311() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 11) else 1)' >/dev/null 2>&1
}

verify_active_conda_toolchain() {
  local env_name=$1 active_python active_pip active_env

  [[ -n ${CONDA_PREFIX:-} && -d "$CONDA_PREFIX" ]] \
    || die 'CONDA_PREFIX 未设置或目录不存在。'
  active_env=${CONDA_DEFAULT_ENV:-}
  [[ "$active_env" == "$env_name" || "$active_env" == "$CONDA_PREFIX" ]] \
    || die "当前 Conda 环境不是 $env_name：${active_env:-<未激活>}"
  [[ $(basename -- "$CONDA_PREFIX") == "$env_name" ]] \
    || die "CONDA_PREFIX 未指向 $env_name 环境：$CONDA_PREFIX"

  hash -r
  active_python=$(command -v python 2>/dev/null || true)
  active_pip=$(command -v pip 2>/dev/null || true)
  [[ "$active_python" == "$CONDA_PREFIX/bin/python" ]] \
    || die "python 未指向当前 Conda 环境：${active_python:-<未找到>}"
  [[ "$active_pip" == "$CONDA_PREFIX/bin/pip" ]] \
    || die "pip 未指向当前 Conda 环境：${active_pip:-<未找到>}"

  PYTHONNOUSERSITE=1 "$active_python" - <<'PY'
import os
import sys

import pip

prefix = os.path.realpath(os.environ["CONDA_PREFIX"])
python_prefix = os.path.realpath(sys.prefix)
pip_path = os.path.realpath(pip.__file__)

if python_prefix != prefix:
    raise SystemExit(f"Python sys.prefix 不属于当前 Conda 环境：{python_prefix}")
if os.path.commonpath((prefix, pip_path)) != prefix:
    raise SystemExit(f"pip 模块不属于当前 Conda 环境：{pip_path}")
PY

  success "Python：$active_python"
  success "pip：$active_pip"
  "$active_python" --version
  PYTHONNOUSERSITE=1 "$active_python" -m pip --version
}

create_llamafactory_conda_env() {
  local conda_exe=$1

  info 'Anaconda defaults channels 可能要求接受服务条款；conda-forge 不使用这些 defaults channels。'
  if confirm '是否仅使用 conda-forge 创建 llamafactory 环境？' Y; then
    "$conda_exe" create -y -n "$CONDA_ENV_NAME" \
      --override-channels --channel conda-forge \
      python=3.11 pip
    return
  fi

  warn '选择 defaults 前，必须由你本人查看并接受适用的 Anaconda 服务条款。'
  info '查看条款状态：conda tos'
  info '查看条款链接：conda tos view'
  if ! confirm '是否确认你已自行处理相关条款，并继续使用当前默认 channels？' N; then
    die '已停止创建环境；可重新运行并选择 conda-forge。'
  fi
  "$conda_exe" create -y -n "$CONDA_ENV_NAME" python=3.11 pip
}

prepare_source() {
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    info '检测到已有 LlamaFactory 源码，尝试快进更新。'
    git -C "$SOURCE_DIR" pull --ff-only
  elif [[ -e "$SOURCE_DIR" ]]; then
    die "目标路径已存在且不是 Git 仓库：$SOURCE_DIR"
  else
    git clone --depth 1 "$REPOSITORY_URL" "$SOURCE_DIR"
  fi
}

write_config() {
  local mode=$1 conda_exe=${2-}
  mkdir -p "$CONFIG_DIR"
  {
    printf 'INSTALL_MODE=%s\n' "$mode"
    printf 'SOURCE_DIR=%s\n' "$SOURCE_DIR"
    printf 'CONDA_ENV_NAME=%s\n' "$CONDA_ENV_NAME"
    printf 'CONDA_EXE=%s\n' "$conda_exe"
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

check_command_targets() {
  local command_path expected_target="$RUNTIME_DIR/llamafactory-webui"
  for command_path in "$BIN_DIR/llamafactory-webui" "$BIN_DIR/llamafactory-webui-start" "$BIN_DIR/llamafactory-webui-stop"; do
    if [[ -e "$command_path" || -L "$command_path" ]]; then
      if [[ ! -L "$command_path" || $(readlink -- "$command_path") != "$expected_target" ]]; then
        die "拒绝覆盖不属于本脚本的文件：$command_path"
      fi
    fi
  done
}

install_commands() {
  mkdir -p "$RUNTIME_DIR" "$BIN_DIR"
  check_command_targets
  install -m 0644 "$SCRIPT_DIR/lib/ui.sh" "$RUNTIME_DIR/ui.sh"
  install -m 0755 "$SCRIPT_DIR/bin/llamafactory-webui" "$RUNTIME_DIR/llamafactory-webui"
  ln -sfn "$RUNTIME_DIR/llamafactory-webui" "$BIN_DIR/llamafactory-webui"
  ln -sfn "$RUNTIME_DIR/llamafactory-webui" "$BIN_DIR/llamafactory-webui-start"
  ln -sfn "$RUNTIME_DIR/llamafactory-webui" "$BIN_DIR/llamafactory-webui-stop"
}

main() {
  local conda_exe='' python_bin

  step '检查 Ubuntu 用户环境'
  require_ubuntu

  check_conda_setup

  if ! confirm '是否使用 Conda 创建 llamafactory（Python 3.11）环境？' Y; then
    warn '已选择不使用 Conda；安装脚本不会创建 venv，后续 LlamaFactory 安装流程已全部跳过。'
    return 0
  fi

  require_command git
  mkdir -p "$INSTALL_ROOT"
  check_command_targets

  step '准备 Conda 环境'
  if ! conda_exe=$(find_conda); then
    confirm '未找到 Conda，是否将 Miniconda 安装到 ~/.local/miniconda3？' Y || die '已取消：使用 Conda 需要先安装 Conda。'
    require_command curl
    conda_exe=$(install_miniconda)
  fi
  activate_conda_environment "$conda_exe" base
  if "$conda_exe" env list | awk -v name="$CONDA_ENV_NAME" '$1 == name { found=1 } END { exit !found }'; then
    info "Conda 环境 $CONDA_ENV_NAME 已存在，将继续使用。"
  else
    create_llamafactory_conda_env "$conda_exe"
  fi
  activate_conda_environment "$conda_exe" "$CONDA_ENV_NAME"
  step '验证 Conda Python 与 pip'
  verify_active_conda_toolchain "$CONDA_ENV_NAME"
  python_bin=$(command -v python)
  python_is_311 "$python_bin" || die "现有 $CONDA_ENV_NAME 环境不是 Python 3.11，请先移除或改名。"

  step '获取并安装 LlamaFactory'
  prepare_source
  (
    cd "$SOURCE_DIR"
    PYTHONNOUSERSITE=1 pip install -e .
    PYTHONNOUSERSITE=1 pip install -r requirements/metrics.txt
    llamafactory-cli version
  )

  step '安装用户命令'
  write_config conda "$conda_exe"
  install_commands

  success 'LlamaFactory 安装完成。'
  printf '  安装模式：Conda\n  源码目录：%s\n  管理命令：%s\n' "$SOURCE_DIR" "$BIN_DIR/llamafactory-webui"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR 尚未加入 PATH。请将下面一行加入 ~/.bashrc 后重新登录："
       printf '  export PATH="$HOME/.local/bin:$PATH"\n' ;;
  esac
  info '启动：llamafactory-webui start（或 llamafactory-webui-start）'
  info '停止：llamafactory-webui stop（或 llamafactory-webui-stop）'
}

main "$@"
