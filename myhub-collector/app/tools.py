"""可选外部工具：目前只有 YouTube 解 JS 挑战用的 Deno。

Deno 是单个可执行文件（压缩包约 40 MB，解压后约 90 MB），放不进 git（``data/`` 本来就被忽略），
所以换机器 / 清空 data 后由这里自动下载到 ``<DATA_DIR>/tools/deno/``。

入口：``python -m app deps``（启动脚本会先跑一次，已存在时秒过）。
"""
from __future__ import annotations

import logging
import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

logger = logging.getLogger(__name__)

# 官方只发 GitHub Release：国内直连常年 50 KB/s，40 MB 要十几分钟，所以先走 npmmirror 镜像
# （实测 8 MB/s），镜像挑不到版本再回落到 GitHub。
DENO_MIRROR_INDEX = "https://registry.npmmirror.com/-/binary/deno/"
DENO_SOURCES = (
    "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip",
)
DENO_HOME = "https://deno.com/"
_MIRROR_TRIES = 3          # 镜像目录里最新几个版本依次试
_MIN_DENO_BYTES = 10 * 1024 * 1024


def deno_exe_name() -> str:
    return "deno.exe" if os.name == "nt" else "deno"


def deno_target() -> Path:
    """内置安装位置：<DATA_DIR>/tools/deno/deno[.exe]。"""
    from app.config import get_settings

    return get_settings().data_path / "tools" / "deno" / deno_exe_name()


def _proxy_kwargs(proxy: str) -> dict:
    """与 yt-dlp 侧保持同一套语义：direct/空 = 直连，system = 跟随系统代理，其它按 URL。"""
    if proxy == "system":
        return {"trust_env": True}
    if proxy in ("", "direct"):
        return {"trust_env": False}
    if "://" not in proxy:  # 用户常只写 127.0.0.1:7890
        proxy = "http://" + proxy
    return {"proxy": proxy}


def _fetch(url: str, dest: Path, proxy: str, quiet: bool) -> int:
    """下载到 dest，返回字节数；进度写 stderr，不污染 stdout。"""
    import httpx

    # httpx 会把带签名的重定向 URL 整条打进 INFO 日志，下载时刷屏
    logging.getLogger("httpx").setLevel(logging.WARNING)

    kwargs: dict = {
        "follow_redirects": True,
        "timeout": httpx.Timeout(120.0, connect=15.0),
    }
    kwargs.update(_proxy_kwargs(proxy))

    last_pct = -1
    with httpx.Client(**kwargs) as client:
        with client.stream("GET", url) as resp:
            resp.raise_for_status()
            total = int(resp.headers.get("content-length") or 0)
            done = 0
            with dest.open("wb") as fh:
                for chunk in resp.iter_bytes(256 * 1024):
                    fh.write(chunk)
                    done += len(chunk)
                    if quiet:
                        continue
                    if total:
                        pct = done * 100 // total
                        if pct == last_pct:
                            continue
                        last_pct = pct
                        text = f"  Deno {pct:3d}%  {done / 1048576:.1f}/{total / 1048576:.1f} MB"
                    else:
                        text = f"  Deno {done / 1048576:.1f} MB"
                    print("\r" + text, end="", file=sys.stderr, flush=True)
    if not quiet:
        print(file=sys.stderr)
    return done


def _unzip(zip_path: Path, target: Path, exe: str) -> None:
    """从官方 zip 里取出 deno 可执行文件（zip 根目录即单文件）。"""
    with zipfile.ZipFile(zip_path) as zf:
        member = next((n for n in zf.namelist() if Path(n).name.lower() == exe.lower()), "")
        if not member:
            raise RuntimeError(f"压缩包里没有 {exe}")
        tmp = target.with_suffix(target.suffix + ".part")
        with zf.open(member) as src, tmp.open("wb") as dst:
            shutil.copyfileobj(src, dst)
    os.replace(tmp, target)
    if os.name != "nt":
        target.chmod(0o755)


def deno_status() -> tuple[bool, str]:
    """只做本地检查、不联网下载（启动脚本用，必须毫秒级返回）。"""
    # 这里不调 find_deno()：那条路会连带 import yt_dlp，启动脚本里没必要背这个开销
    if (target := deno_target()).exists():
        return True, str(target)
    if found := shutil.which("deno"):
        return True, found
    return False, "未安装（需要 YouTube 完整下载时执行：python -m app deps）"


def _zip_name() -> str:
    return "deno-x86_64-pc-windows-msvc.zip"


def _mirror_sources(proxy: str) -> list[str]:
    """从 npmmirror 目录列表里挑最新几个版本的 zip 地址；取不到就返回空列表。"""
    import httpx

    logging.getLogger("httpx").setLevel(logging.WARNING)
    kwargs: dict = {
        "follow_redirects": True,
        "timeout": httpx.Timeout(10.0, connect=5.0),
    }
    kwargs.update(_proxy_kwargs(proxy))
    try:
        with httpx.Client(**kwargs) as client:
            items = client.get(DENO_MIRROR_INDEX).raise_for_status().json()
        versions: list[tuple[tuple[int, ...], str]] = []
        for item in items:
            name = str(item.get("name") or "").rstrip("/")
            if not name.startswith("v"):
                continue
            nums = tuple(int(p) for p in name[1:].split(".") if p.isdigit())
            if len(nums) == 3:
                versions.append((nums, name))
        versions.sort(reverse=True)
        return [f"{DENO_MIRROR_INDEX}{name}/{_zip_name()}" for _, name in versions[:_MIRROR_TRIES]]
    except Exception as exc:  # noqa: BLE001 镜像不可用就回落 GitHub
        logger.debug("读取 Deno 镜像目录失败：%s", exc)
        return []


def ensure_deno(quiet: bool = False, force: bool = False) -> tuple[bool, str]:
    """确保 Deno 可用。返回 (是否可用, 路径或失败原因)。

    已经放在内置目录或 PATH 里就直接用；否则下载到内置目录（约 40 MB，仅首次）。
    """
    if not force:
        ok, info = deno_status()
        if ok:
            return True, info

    if os.name != "nt":
        return False, f"自动安装只支持 Windows，其它系统请参考 {DENO_HOME}"

    from app.config import get_settings

    settings = get_settings()
    target = deno_target()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()  # 损坏的残留，重新下

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="myhub-deno-") as tmpdir:
        zip_path = Path(tmpdir) / "deno.zip"
        for url in (*_mirror_sources(settings.proxy), *DENO_SOURCES):
            try:
                if not quiet:
                    print(f"  来源：{url}", file=sys.stderr)
                _fetch(url, zip_path, proxy=settings.proxy, quiet=quiet)
                _unzip(zip_path, target, deno_exe_name())
                break
            except Exception as exc:  # noqa: BLE001 换下一个源继续试
                logger.debug("下载 Deno 失败 %s: %s", url, exc)
                failures.append(f"{type(exc).__name__}: {exc}")
                zip_path.unlink(missing_ok=True)
        else:
            return False, "下载失败（网络不通时可设置 PROXY 后重试）：" + "；".join(failures)

    if not target.exists() or target.stat().st_size < _MIN_DENO_BYTES:
        target.unlink(missing_ok=True)
        return False, "下载到的文件不完整，已删除；请重试"

    return True, f"{target}（{target.stat().st_size / 1048576:.0f} MB）"
