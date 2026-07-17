#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

readonly CONDA_ENV_NAME='llamafactory'
readonly INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/llamafactory"
readonly SOURCE_DIR="$INSTALL_ROOT/source"
readonly VENV_DIR="$INSTALL_ROOT/venv"
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
      bash "$SCRIPT_DIR/setup-conda.sh"
    fi
  else
    warn '当前 PATH、~/.bashrc 和常见安装路径中均未检测到 Conda。'
    if confirm '是否手动指定 Conda 路径并执行 setup-conda.sh？' N; then
      bash "$SCRIPT_DIR/setup-conda.sh"
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

python_is_supported() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

python_is_311() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 11) else 1)' >/dev/null 2>&1
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
  local mode=$1 env_path=$2 conda_exe=${3-}
  mkdir -p "$CONFIG_DIR"
  {
    printf 'INSTALL_MODE=%s\n' "$mode"
    printf 'SOURCE_DIR=%s\n' "$SOURCE_DIR"
    printf 'ENV_PATH=%s\n' "$env_path"
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
  local use_conda conda_exe='' conda_base='' conda_sh='' python_bin mode env_path

  step '检查 Ubuntu 用户环境'
  require_ubuntu

  check_conda_setup

  require_command git
  mkdir -p "$INSTALL_ROOT"
  check_command_targets

  if confirm '是否使用 Conda 创建 llamafactory（Python 3.11）环境？' Y; then
    use_conda=1
  else
    use_conda=0
  fi

  if (( use_conda )); then
    step '准备 Conda 环境'
    if ! conda_exe=$(find_conda); then
      confirm '未找到 Conda，是否将 Miniconda 安装到 ~/.local/miniconda3？' Y || die '已取消：使用 Conda 需要先安装 Conda。'
      require_command curl
      conda_exe=$(install_miniconda)
    fi
    conda_base=$("$conda_exe" info --base)
    conda_sh="$conda_base/etc/profile.d/conda.sh"
    [[ -r "$conda_sh" ]] || die "找不到 Conda 初始化脚本：$conda_sh"
    if "$conda_exe" env list | awk -v name="$CONDA_ENV_NAME" '$1 == name { found=1 } END { exit !found }'; then
      info "Conda 环境 $CONDA_ENV_NAME 已存在，将继续使用。"
    else
      "$conda_exe" create -y -n "$CONDA_ENV_NAME" python=3.11 pip
    fi
    env_path=$("$conda_exe" env list | awk -v name="$CONDA_ENV_NAME" '$1 == name { print $NF; exit }')
    [[ -n "$env_path" && -x "$env_path/bin/python" ]] || die "无法确定 Conda 环境 $CONDA_ENV_NAME 的目录。"
    python_bin="$env_path/bin/python"
    python_is_311 "$python_bin" || die "现有 $CONDA_ENV_NAME 环境不是 Python 3.11，请先移除或改名。"
    mode='conda'
  else
    step '准备独立 Python venv'
    if command -v python3.11 >/dev/null 2>&1; then
      python_bin=$(command -v python3.11)
    elif command -v python3 >/dev/null 2>&1 && python_is_supported "$(command -v python3)"; then
      python_bin=$(command -v python3)
    else
      die '未找到 Python 3.11+。可重新运行并选择 Conda，或请管理员安装 python3.11-venv。'
    fi
    "$python_bin" -m venv "$VENV_DIR" || die '创建 venv 失败；Ubuntu 通常需要由管理员安装 python3.11-venv。'
    python_bin="$VENV_DIR/bin/python"
    mode='venv'
    env_path="$VENV_DIR"
  fi

  step '获取并安装 LlamaFactory'
  prepare_source
  "$python_bin" -m pip install --upgrade pip
  "$python_bin" -m pip install -e "$SOURCE_DIR"
  "$python_bin" -m pip install -r "$SOURCE_DIR/requirements/metrics.txt"
  "$env_path/bin/llamafactory-cli" version

  step '安装用户命令'
  write_config "$mode" "$env_path" "$conda_exe"
  install_commands

  success 'LlamaFactory 安装完成。'
  printf '  安装模式：%s\n  源码目录：%s\n  管理命令：%s\n' "$mode" "$SOURCE_DIR" "$BIN_DIR/llamafactory-webui"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR 尚未加入 PATH。请将下面一行加入 ~/.bashrc 后重新登录："
       printf '  export PATH="$HOME/.local/bin:$PATH"\n' ;;
  esac
  info '启动：llamafactory-webui start（或 llamafactory-webui-start）'
  info '停止：llamafactory-webui stop（或 llamafactory-webui-stop）'
}

main "$@"
