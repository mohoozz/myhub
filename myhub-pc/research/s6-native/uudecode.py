"""将 libarchive 测试仓库的 uuencoded 档案还原为二进制。

libarchive 把所有二进制测试档案以 uuencode 文本形式入库，
需解码后才能作为真实 rar/cbr 素材使用。
（Python 3.13 起移除了 uu 模块，这里用 binascii.a2b_uu 自行解析。）
"""

import binascii
import sys
from pathlib import Path


def uudecode(src: Path, dst: Path) -> int:
    data = bytearray()
    started = False

    for raw in src.read_text(encoding="ascii", errors="replace").splitlines():
        line = raw.rstrip("\r\n")

        if not started:
            if line.startswith("begin"):
                started = True
            continue

        if line in ("end", "`") or line.strip() == "end":
            break
        if not line:
            continue

        try:
            data += binascii.a2b_uu(line)
        except binascii.Error:
            # 末行可能带填充噪声，按首字符声明的长度重算
            length = (ord(line[0]) - 32) & 63
            nbytes = ((length * 4 + 2) // 3) + 1
            data += binascii.a2b_uu(line[:nbytes])

    dst.write_bytes(bytes(data))
    return len(data)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: uudecode.py <input.uu> <output>")
        return 2

    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    n = uudecode(src, dst)

    head = dst.read_bytes()[:8]
    print(f"{dst.name}: {n} bytes, header = {head.hex(' ').upper()}")

    # RAR4: 52 61 72 21 1A 07 00 / RAR5: 52 61 72 21 1A 07 01 00
    if head[:4] == b"Rar!":
        print("  -> valid RAR signature")
    else:
        print("  -> WARNING: not a RAR signature")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
