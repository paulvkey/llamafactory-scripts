# LlamaFactory Ubuntu 用户级安装脚本

用于在 Ubuntu 上交互式安装、卸载和管理 LlamaFactory WebUI。整个过程不使用
`sudo`，不会修改系统级 Python 或系统目录。终端颜色与交互输出统一复用
[`lib/ui.sh`](lib/ui.sh)。

## 功能

- 创建名为 `llamafactory`、Python 3.11 的 Conda 环境；未安装 Conda 时可选择
  将 Miniconda 安装到 `~/.local/miniconda3`。
- 如果不选择使用 Conda，脚本会提示后直接退出，不创建 venv，也不继续安装。
- 从官方仓库安装 LlamaFactory 及 metrics 依赖。
- 启动 WebUI 前展示 NVIDIA GPU 型号、驱动、温度、利用率和显存占用，并通过
  `CUDA_VISIBLE_DEVICES` 选择设备。
- 后台启停、状态查询和日志查看；Conda 安装模式下启动时自动激活环境。

## 安装与卸载

```bash
git clone https://ghfast.top/https://github.com/paulvkey/llamafactory-scripts.git
chmod +x install.sh uninstall.sh
./install.sh
```

脚本将命令安装到 `~/.local/bin`。如果该目录不在 `PATH`，按安装完成时的提示将
它加入 `~/.bashrc`。

安装开始时会先检查 Conda、`~/.bashrc` 初始化块、`envs_dirs` 和 `pkgs_dirs`。如果未检测到推荐的
`/data1/conda_envs/users/$USER` 与 `/data1/conda_pkgs/users/$USER`，会默认建议
立即执行 `setup-conda.sh`；配置已经存在时则默认跳过。若 Conda 位于自定义目录，
安装脚本也会尝试从 `~/.bashrc` 的初始化块中识别其路径。

如果安装过程中执行了 `setup-conda.sh`，`install.sh` 会在当前安装进程中主动加载
`conda.sh`：先激活 base 创建环境，再激活 `llamafactory` 安装全部依赖，因此无需
中断安装去手动执行 `source ~/.bashrc`。单独运行 `setup-conda.sh` 时，新配置仍需
执行 `source ~/.bashrc` 或重新登录后才会影响当前终端。

创建 `llamafactory` 环境时默认使用 `conda-forge`，并通过 `--override-channels`
忽略 Anaconda defaults，避免在非交互安装中触发 `CondaToSNonInteractiveError`。
如果选择使用 defaults，脚本会要求管理员自行查看并处理适用的 Anaconda 服务条款，
不会自动代替用户接受法律条款。

安装 LlamaFactory 前，脚本会验证 `CONDA_DEFAULT_ENV`、`CONDA_PREFIX`、`python`、
`pip`、Python 的 `sys.prefix` 以及 pip 模块路径，确保它们全部属于 `llamafactory`
环境。依赖安装同时设置 `PYTHONNOUSERSITE=1`，防止误用用户目录中的 Python 包。
验证通过后，LlamaFactory 本体按照官方方式执行 `pip install -e .` 和
`pip install -r requirements/metrics.txt`，不额外升级 pip。

`install.sh` 可以重复运行。脚本会检查配置、源码、Conda 环境、Python 版本、
`llamafactory-cli`、WebUI 运行脚本和命令链接；检测到完整安装时默认跳过全部步骤，
仅询问是否更新。选择更新后才会拉取源码并刷新依赖和管理脚本；检测到安装不完整时
则继续执行安装或修复流程。

```bash
./uninstall.sh
```

卸载会先确认，再删除脚本管理的用户级源码、命令、配置和日志。若使用
Conda，会单独询问是否删除 `llamafactory` 环境；Miniconda 本身始终保留。

## 配置共享存储中的 Conda 目录

`setup-conda.sh` 用于配置 Bash 的 Conda 初始化块，并交互设置当前用户的环境目录
和包缓存目录。默认值为：

```text
Miniconda: /data1/user/miniconda3
环境目录:  /data1/conda_envs/users/$USER
包缓存:    /data1/conda_pkgs/users/$USER
```

运行：

```bash
chmod +x setup-conda.sh
./setup-conda.sh
```

脚本会创建所选目录，向 `~/.bashrc` 追加或替换标准 Conda 初始化块，随后执行：

```bash
conda config --prepend envs_dirs /data1/conda_envs/users/$USER
conda config --prepend pkgs_dirs /data1/conda_pkgs/users/$USER
conda config --show envs_dirs
conda config --show pkgs_dirs
```

替换已有初始化块之前会备份 `~/.bashrc`。脚本不会删除或覆盖其他 Bash 配置。

## 从 Conda base 发布公共命令

管理员可使用 `install-shared-cmd.sh` 将 CLI 包安装到 Conda base，并发布
到 `/usr/local/bin`，让所有用户无需激活 Conda 即可执行。默认安装 `nvitop`，也可
交互输入其他 Conda 包、channel、环境内命令名和公共命令名：

```bash
chmod +x install-shared-cmd.sh
./install-shared-cmd.sh
```

脚本需要由具有 `sudo` 权限的普通管理员账号运行，不应直接使用 root。该方案会让
其他用户能够读取 Conda base 中的文件，但不会授予写权限。完整的交互参数、权限
影响、其他命令示例、验证、恢复和故障排查请参阅
[`docs/install-shared-cmd/README.md`](docs/install-shared-cmd/README.md)。

## WebUI 管理命令

需要在当前终端直接使用 `llamafactory-cli`、Python 或 pip 时，执行：

```bash
conda activate llamafactory
```

`llamafactory-webui-start` 会自动在后台进程中激活该环境，但不会改变当前终端的
Conda 环境；启动成功后也会显示上面的手动激活提示。

```bash
# 交互展示并选择 GPU
llamafactory-webui start

# 非交互指定 GPU；all 使用全部，none 强制 CPU
llamafactory-webui start --gpus 0,1
llamafactory-webui start --gpus all
llamafactory-webui start --gpus none

# 默认仅监听服务器本机的 127.0.0.1:7860；也可以指定地址和端口
llamafactory-webui start --host 127.0.0.1 --port 7860

llamafactory-webui status
llamafactory-webui logs
llamafactory-webui logs -f
llamafactory-webui stop

# 查看总帮助或子命令帮助
llamafactory-webui --help
llamafactory-webui help start
llamafactory-webui start --help
```

也可以使用直达命令：

```bash
llamafactory-webui-start --gpus 0
llamafactory-webui-stop
```

需要向 `llamafactory-cli webui` 透传参数时，将参数放在 `--` 后：

```bash
llamafactory-webui start --gpus 0 -- --help
```

如果通过 SSH 登录 Ubuntu 服务器，浏览器中打开的 `127.0.0.1` 默认指向浏览器所在的
电脑，而不是服务器。推荐在自己电脑另开终端建立 SSH 隧道：

```bash
ssh -N -L 7860:127.0.0.1:7860 用户名@服务器地址
```

保持该命令运行，再在自己电脑打开 <http://127.0.0.1:7860/>。若确实需要从局域网
直接访问，可使用 `llamafactory-webui start --host 0.0.0.0 --port 7860`，然后打开
`http://服务器IP:7860/`；这种方式会把 WebUI 暴露到服务器网络接口，应同时配置好
防火墙和访问控制，避免暴露到不可信网络。

如果页面仍无法打开，先检查进程、监听端口和日志：

```bash
llamafactory-webui status
llamafactory-webui logs
curl -I http://127.0.0.1:7860/
```

## 下载 Hugging Face 数据集

安装脚本会同时安装 `llamafactory-data-download` 命令。该命令会自动激活
`llamafactory` Conda 环境，不要求当前终端提前执行 `conda activate`。

```bash
# 交互输入数据集 Repo ID
llamafactory-data-download

# 直接指定 Repo ID，保存到 ~/LlamaFactory/data/OpenR1-Math-220k
llamafactory-data-download open-r1/OpenR1-Math-220k

# 自定义 data 目录下的目录名
llamafactory-data-download open-r1/OpenR1-Math-220k --name math_training

# 查看帮助
llamafactory-data-download --help
```

数据统一保存在 `~/LlamaFactory/data/<数据集目录名>`。重复执行命令时会检查远端
更新并复用本地下载元数据。

## 默认路径

| 内容                 | 路径                                    |
| -------------------- | --------------------------------------- |
| LlamaFactory 源码    | `~/LlamaFactory`                        |
| WebUI 运行脚本       | `~/.local/share/llamafactory`           |
| 管理命令             | `~/.local/bin`                          |
| 安装配置             | `~/.config/llamafactory-scripts/config` |
| PID 与日志           | `~/.local/state/llamafactory`           |

源码目录固定为 `~/LlamaFactory`。其他目录可通过 `XDG_DATA_HOME`、
`XDG_CONFIG_HOME` 和 `XDG_STATE_HOME` 覆盖相应的 XDG 路径。
如果检测到旧版本脚本创建的 `~/.local/share/llamafactory/source`，安装时会询问
是否将它迁移到新的源码目录。
