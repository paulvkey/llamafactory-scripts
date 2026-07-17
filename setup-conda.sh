#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

readonly CURRENT_USER="${USER:-$(id -un)}"
readonly BASHRC_FILE="$HOME/.bashrc"
readonly DEFAULT_CONDA_ROOT='/data1/user/miniconda3'
readonly DEFAULT_ENVS_DIR="/data1/conda_envs/users/$CURRENT_USER"
readonly DEFAULT_PKGS_DIR="/data1/conda_pkgs/users/$CURRENT_USER"
readonly CONDA_BLOCK_START='# >>> conda initialize >>>'
readonly CONDA_BLOCK_END='# <<< conda initialize <<<'

trap 'error "配置失败（第 ${LINENO} 行）。请检查上方输出。"' ERR

validate_path() {
  local label=$1 path=$2
  [[ "$path" == /* ]] || die "$label 必须是绝对路径：$path"
  [[ "$path" =~ ^/[A-Za-z0-9._/@+-]+$ ]] || die "$label 包含不支持的字符：$path"
  [[ "$path" != / ]] || die "$label 不能是根目录。"
}

write_conda_block() {
  local conda_root=$1 conda_exe="$1/bin/conda"
  {
    printf '\n%s\n' "$CONDA_BLOCK_START"
    printf '%s\n' "# !! Contents within this block are managed by 'conda init' !!"
    printf '%s\n' "__conda_setup=\"\$('${conda_exe}' 'shell.bash' 'hook' 2> /dev/null)\""
    printf '%s\n' 'if [ $? -eq 0 ]; then'
    printf '%s\n' '    eval "$__conda_setup"'
    printf '%s\n' 'else'
    printf '%s\n' "    if [ -f \"${conda_root}/etc/profile.d/conda.sh\" ]; then"
    printf '%s\n' "        . \"${conda_root}/etc/profile.d/conda.sh\""
    printf '%s\n' '    else'
    printf '%s\n' "        export PATH=\"${conda_root}/bin:\$PATH\""
    printf '%s\n' '    fi'
    printf '%s\n' 'fi'
    printf '%s\n' 'unset __conda_setup'
    printf '%s\n' "$CONDA_BLOCK_END"
  } >>"$BASHRC_FILE"
}

configure_bashrc() {
  local conda_root=$1 backup_file start_count end_count
  touch "$BASHRC_FILE"

  start_count=$(awk -v marker="$CONDA_BLOCK_START" '$0 == marker { count++ } END { print count + 0 }' "$BASHRC_FILE")
  end_count=$(awk -v marker="$CONDA_BLOCK_END" '$0 == marker { count++ } END { print count + 0 }' "$BASHRC_FILE")
  [[ "$start_count" == "$end_count" ]] || die "$BASHRC_FILE 中的 Conda 初始化标记不完整，请先手动检查。"

  if (( start_count > 0 )); then
    if confirm "$BASHRC_FILE 中已有 Conda 初始化块，是否替换？" Y; then
      backup_file="${BASHRC_FILE}.conda-backup.$(date +%Y%m%d%H%M%S)"
      cp -p -- "$BASHRC_FILE" "$backup_file"
      sed -i "/^# >>> conda initialize >>>\$/,/^# <<< conda initialize <<<\$/d" "$BASHRC_FILE"
      write_conda_block "$conda_root"
      success "已替换 Conda 初始化块；备份：$backup_file"
    else
      warn '已保留现有 Conda 初始化块。'
    fi
  else
    write_conda_block "$conda_root"
    success "已将 Conda 初始化块追加到 $BASHRC_FILE"
  fi
}

main() {
  local conda_root envs_dir pkgs_dir conda_exe

  [[ ${EUID:-$(id -u)} -ne 0 ]] || die '请勿使用 root 或 sudo 运行；本脚本只配置当前用户。'

  step '设置 Conda 路径'
  conda_root=$(ask 'Miniconda 安装目录' "$DEFAULT_CONDA_ROOT")
  envs_dir=$(ask 'Conda 环境存放目录' "$DEFAULT_ENVS_DIR")
  pkgs_dir=$(ask 'Conda 包缓存目录' "$DEFAULT_PKGS_DIR")

  validate_path 'Miniconda 安装目录' "$conda_root"
  validate_path 'Conda 环境目录' "$envs_dir"
  validate_path 'Conda 包缓存目录' "$pkgs_dir"
  conda_exe="$conda_root/bin/conda"
  [[ -x "$conda_exe" ]] || die "找不到可执行的 Conda：$conda_exe"

  printf '\n  Miniconda：%s\n  环境目录：%s\n  包缓存目录：%s\n' "$conda_root" "$envs_dir" "$pkgs_dir"
  confirm '确认写入 ~/.bashrc 并更新 Conda 配置？' Y || { warn '已取消配置。'; return; }

  step '创建 Conda 环境与包缓存目录'
  mkdir -p -- "$envs_dir" "$pkgs_dir"
  success '目录创建完成。'

  step '配置 Bash 初始化块'
  configure_bashrc "$conda_root"

  step '配置 Conda 环境与包缓存搜索路径'
  "$conda_exe" config --prepend envs_dirs "$envs_dir"
  "$conda_exe" config --prepend pkgs_dirs "$pkgs_dir"

  step '当前 Conda 目录配置'
  "$conda_exe" config --show envs_dirs
  "$conda_exe" config --show pkgs_dirs

  success 'Conda 用户目录配置完成。'
  info '执行 source ~/.bashrc 或重新登录后，Conda 初始化配置生效。'
}

main "$@"
