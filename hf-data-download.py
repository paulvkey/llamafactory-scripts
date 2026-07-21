import argparse
import os
from pathlib import Path

# HF_ENDPOINT 必须在导入 huggingface_hub 前设置，确保镜像地址能够生效。
os.environ["HF_ENDPOINT"] = "https://hf-mirror.com"

from huggingface_hub import snapshot_download

DEFAULT_REPO_ID = "Henrychur/MedS-Bench"
DATA_DIR = Path.home() / "LlamaFactory" / "data"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="下载 Hugging Face 数据集到 ~/LlamaFactory/data。",
        epilog=(
            "示例：%(prog)s open-r1/OpenR1-Math-220k；"
            "%(prog)s org/dataset --name my_dataset"
        ),
    )
    parser.add_argument(
        "repo_id",
        nargs="?",
        help=f"Hugging Face 数据集仓库 ID（默认交互值：{DEFAULT_REPO_ID}）",
    )
    parser.add_argument(
        "--name",
        help="data 目录下的本地目录名；默认使用 repo_id 的最后一段",
    )
    args = parser.parse_args()

    if args.repo_id is None:
        try:
            args.repo_id = input(f"数据集 Repo ID [{DEFAULT_REPO_ID}]: ").strip()
        except EOFError:
            parser.error("非交互运行时必须提供 repo_id。")
        args.repo_id = args.repo_id or DEFAULT_REPO_ID

    args.repo_id = args.repo_id.strip().rstrip("/")
    if not args.repo_id or any(char.isspace() for char in args.repo_id):
        parser.error("repo_id 不能为空或包含空白字符。")

    local_name = args.name or args.repo_id.rsplit("/", 1)[-1]
    if not local_name or local_name in {".", ".."} or Path(local_name).name != local_name:
        parser.error("--name 必须是单个安全的目录名，不能包含路径。")
    args.local_dir = DATA_DIR / local_name
    return args


def main() -> int:
    args = parse_args()
    args.local_dir.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {args.repo_id} to: {args.local_dir}")

    try:
        downloaded_path = snapshot_download(
            repo_id=args.repo_id,
            repo_type="dataset",
            local_dir=args.local_dir,
        )
    except Exception as exc:
        print(f"Download failed: {exc}")
        return 1

    print(f"Download completed successfully: {downloaded_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
