# install-shared-cmd 使用说明

[`install-shared-cmd.sh`](../../install-shared-cmd.sh) 用于由管理员将 Conda CLI 包
安装到 `base` 环境，再将其中的命令发布到 `/usr/local/bin`。其他用户无需执行
`conda activate`，即可直接使用公共命令。

脚本默认安装 `conda-forge::nvitop`，同时保留了通用交互参数，可用于发布其他
Conda CLI 包。

## 使用条件

- Ubuntu 或兼容的 Linux 环境。
- 使用具有 `sudo` 权限的普通管理员账号运行，不能直接以 root 运行。
- 已安装 Conda，且管理员能够修改 Conda `base` 环境。
- `/usr/local/bin` 位于所有用户的 `PATH` 中。
- 发布 GPU 工具时，目标用户还需要具有访问 NVIDIA 驱动和设备的权限。

脚本会依次从以下位置寻找 Conda：

1. 当前 `PATH` 中的 `conda`。
2. `~/.bashrc` 的 Conda 初始化块。
3. `/data1/user/miniconda3/bin/conda`。
4. `~/miniconda3`、`~/anaconda3` 和 `~/.local/miniconda3`。

## 快速开始：安装 nvitop

在项目根目录运行：

```bash
chmod +x install-shared-cmd.sh
./install-shared-cmd.sh
```

直接接受默认值即可：

| 交互项 | 默认值 | 含义 |
| --- | --- | --- |
| Conda 包名 | `nvitop` | 传给 `conda install` 的包名 |
| Conda channel | `conda-forge` | 下载包的 channel |
| 环境内命令名 | `nvitop` | 安装后预期位于 `<conda-base>/bin` 的命令 |
| 公共命令名 | `nvitop` | 发布到 `/usr/local/bin` 的名称 |
| 使用 `--version` 验证 | `Y` | 发布前后验证命令能否运行 |

实际安装命令等价于：

```bash
conda install --name base --channel conda-forge --yes nvitop
```

发布完成后的结构类似：

```text
/usr/local/bin/nvitop
  -> /data1/user/miniconda3/bin/nvitop
```

所有用户可直接运行：

```bash
nvitop
```

## 安装其他公共命令

再次运行脚本，并根据提示输入不同的包名和命令名即可。包名和可执行命令名不一定
相同。例如安装 `httpie` 时，可输入：

```text
Conda 包名: httpie
Conda channel: conda-forge
环境内命令名: http
公共命令名: http
```

如果目标命令不支持 `--version`，应在验证提示中选择 `N`，安装后再使用该工具
支持的参数手动验证。

## 权限变更

为了让未激活 Conda 的其他用户运行 base 中的 Python 和依赖，脚本会先展示并
再次确认以下操作：

```text
chmod -R a+rX <conda-base>
chmod o+x <conda-base 的各级父目录>
```

这些操作：

- 为其他用户增加读取文件和执行程序/进入目录的权限。
- 不会增加组用户或其他用户的写权限。
- 会使其他用户能够读取 Conda base 内的全部普通文件，而不只是本次安装的包。

如果 base 中保存了令牌、私有配置或其他敏感内容，请在权限确认时选择 `N`，并改用
专门的公共 Conda 环境，不要公开个人 base。

## 同名命令处理

如果 `/usr/local/bin/<命令>` 已指向本次目标，脚本不会重复创建。

如果该路径存在其他文件或链接，脚本会展示现有对象并询问是否替换。确认后，原命令
会被移动到带时间戳的备份文件，例如：

```text
/usr/local/bin/nvitop.backup.20260720153000
```

如需恢复，可由管理员删除新链接并将备份移回原位：

```bash
sudo rm /usr/local/bin/nvitop
sudo mv /usr/local/bin/nvitop.backup.时间戳 /usr/local/bin/nvitop
```

执行前应使用 `ls -l /usr/local/bin/nvitop*` 核对准确文件名。

## 验证

检查公共命令及其来源：

```bash
type -a nvitop
command -v nvitop
ls -l /usr/local/bin/nvitop
/usr/local/bin/nvitop --version
```

使用一个真实的普通用户验证：

```bash
sudo -u 其他用户名 -H /usr/local/bin/nvitop --version
sudo -u 其他用户名 -H /usr/local/bin/nvitop -1
```

## 常见问题

### 未找到 Conda

确认 Conda 路径和 base 环境：

```bash
/data1/user/miniconda3/bin/conda info --base
```

如果使用自定义路径，可先执行项目根目录中的 `setup-conda.sh`，或将 Conda 正确
初始化到 `~/.bashrc` 后重新运行。

### 安装后找不到环境内命令

有些 Conda 包名和命令名不同。先查看包安装内容及 `base/bin`：

```bash
conda list --name base
ls -l "$(conda info --base)/bin"
```

确认正确的命令名后重新运行脚本。

### 其他用户提示 Permission denied

逐级检查目录权限：

```bash
namei -l /data1/user/miniconda3/bin/nvitop
```

每一级父目录都需要其他用户的执行权限，命令及其 Python 依赖需要读取权限。

### 管理员仍执行到旧版本

管理员自己的 `~/.local/bin` 或已激活的 Conda 环境可能排在 `/usr/local/bin` 前面：

```bash
type -a nvitop
hash -r
```

其他用户不受管理员个人 `~/.local/bin` 的影响。

## 更新与移除

更新公共包后，原来的 `/usr/local/bin` 链接通常无需修改：

```bash
conda update --name base --channel conda-forge nvitop
```

移除前先确认链接目标，再分别删除公共链接和 Conda 包：

```bash
ls -l /usr/local/bin/nvitop
sudo rm /usr/local/bin/nvitop
conda remove --name base nvitop
```

脚本目前只负责安装和发布，不自动卸载公共命令。
