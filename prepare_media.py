"""Create local FAT32 acceptance media and verify it; never opens a physical disk."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import struct
import wave

REPO = Path(__file__).resolve().parent
SECTOR = 512
SPC = 8
CLUSTERS = 65536
RESERVED = 32
FAT_SECTORS = (CLUSTERS + 2 + 127) // 128
DATA_SECTOR = RESERVED + FAT_SECTORS * 2
TOTAL_SECTORS = DATA_SECTOR + CLUSTERS * SPC


def make_bmp(width: int, height: int, color: tuple[int, int, int]) -> bytes:
    """24-bit BMP with direction markers, padding, and optional top-down rows."""
    stride = (width * 3 + 3) & ~3
    pixels = bytearray()
    for stored_y in range(abs(height)):
        y = stored_y if height < 0 else height - 1 - stored_y
        row = bytearray()
        for x in range(width):
            rgb = color
            if x == 0 or y == 0 or x == width - 1 or y == abs(height) - 1:
                rgb = (255, 255, 255)
            if x >= width * 3 // 4 and y >= abs(height) * 3 // 4:
                rgb = (0, 0, 0)
            row.extend(reversed(rgb))
        row.extend(bytes(stride - len(row)))
        pixels.extend(row)
    header = struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
    dib = struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    return header + dib + pixels


def verify_image(path: Path, expected: dict[str, str]) -> dict[str, object]:
    """Read directory and FAT from the image, reconstruct files, check hashes."""
    with path.open("rb") as image:
        boot = image.read(512)
        if boot[510:] != b"\x55\xaa" or struct.unpack_from("<H", boot, 11)[0] != 512:
            raise ValueError("Invalid FAT32 boot sector")
        spc = boot[13]
        reserved = struct.unpack_from("<H", boot, 14)[0]
        fats = boot[16]
        fat_sectors = struct.unpack_from("<I", boot, 36)[0]
        root = struct.unpack_from("<I", boot, 44)[0]
        data_sector = reserved + fats * fat_sectors
        total = struct.unpack_from("<I", boot, 32)[0]
        cluster_count = (total - data_sector) // spc
        if cluster_count < 65525:
            raise ValueError("Volume is not FAT32 by cluster count")
        image.seek(reserved * 512)
        fat = image.read(fat_sectors * 512)
        image.seek((reserved + fat_sectors) * 512)
        if image.read(len(fat)) != fat:
            raise ValueError("FAT copies differ")

        def chain_bytes(first: int) -> tuple[bytes, list[int]]:
            visited: set[int] = set()
            chain: list[int] = []
            payload = bytearray()
            current = first
            while current < 0x0FFFFFF8:
                if current < 2 or current > cluster_count + 1 or current in visited:
                    raise ValueError("Invalid or cyclic cluster chain")
                visited.add(current)
                chain.append(current)
                image.seek((data_sector + (current - 2) * spc) * 512)
                block = image.read(spc * 512)
                if len(block) != spc * 512:
                    raise ValueError("Truncated cluster")
                payload.extend(block)
                current = struct.unpack_from("<I", fat, current * 4)[0] & 0x0FFFFFFF
            return bytes(payload), chain

        directory, _ = chain_bytes(root)
        result: dict[str, object] = {}
        for offset in range(0, len(directory), 32):
            entry = directory[offset:offset + 32]
            if entry[0] == 0:
                break
            if entry[0] == 0xE5 or entry[11] & 0x18 or entry[11] == 0x0F:
                continue
            name = entry[:8].decode("ascii").rstrip() + "." + entry[8:11].decode("ascii").rstrip()
            first = (struct.unpack_from("<H", entry, 20)[0] << 16) | struct.unpack_from("<H", entry, 26)[0]
            size = struct.unpack_from("<I", entry, 28)[0]
            payload, chain = chain_bytes(first)
            if len(payload) < size or hashlib.sha256(payload[:size]).hexdigest() != expected.get(name):
                raise ValueError(f"File hash/length mismatch: {name}")
            result[name] = {"size": size, "clusters": chain, "fragmented": any(b != a + 1 for a, b in zip(chain, chain[1:]))}
        if set(result) != set(expected):
            raise ValueError("Directory file set mismatch")
        return result


def prepare(out: Path) -> Path:
    out.mkdir(parents=True, exist_ok=False)
    files = out / "files"
    files.mkdir()
    pictures = [("00_MAGNT.BMP", 1280, 960, (220, 0, 220)), ("01_CYAN.BMP", 640, -480, (0, 210, 210)),
                ("02_ORANG.BMP", 201, 101, (255, 140, 0)), ("03_GRAY.BMP", 5, 3, (130, 130, 130))]
    for name, width, height, color in pictures:
        (files / name).write_bytes(make_bmp(width, height, color))
    samples = 96000
    with wave.open(str(files / "04_AUDIO.WAV"), "wb") as wav:
        wav.setparams((2, 2, 48000, samples, "NONE", "not compressed"))
        pcm = bytearray()
        for n in range(samples):
            gain = min(1.0, n / 480, (samples - 1 - n) / 480)
            pcm.extend(struct.pack("<hh", *(round(10000 * gain * math.sin(2 * math.pi * frequency * n / 48000))
                                           for frequency in (440, 660))))
        wav.writeframes(pcm)
    boot = bytearray(512)
    boot[:11] = b"\xeb\x58\x90FPGA2026"
    struct.pack_into("<HBHBHHBHHHII", boot, 11, 512, SPC, RESERVED, 2, 0, 0, 0xF8, 0, 63, 255, 0, TOTAL_SECTORS)
    struct.pack_into("<IHHIHH", boot, 36, FAT_SECTORS, 0, 0, 2, 1, 6)
    boot[64] = 0x80
    boot[66] = 0x29
    struct.pack_into("<I", boot, 67, 0x20260919)
    boot[71:82] = b"FPGA_MEDIA "
    boot[82:90] = b"FAT32   "
    boot[510:] = b"\x55\xaa"
    fsinfo = bytearray(512)
    for offset, value in ((0, 0x41615252), (484, 0x61417272), (488, 0xFFFFFFFF), (492, 0xFFFFFFFF), (508, 0xAA550000)):
        struct.pack_into("<I", fsinfo, offset, value)
    fat = bytearray(FAT_SECTORS * 512)
    for cluster, value in ((0, 0x0FFFFFF8), (1, 0xFFFFFFFF), (2, 0x0FFFFFFF)):
        struct.pack_into("<I", fat, cluster * 4, value)
    directory = bytearray(SPC * 512)
    hashes: dict[str, str] = {}
    next_cluster = 5
    target = out / "acceptance_fat32.img"
    with target.open("xb") as image:
        image.truncate(TOTAL_SECTORS * 512)
        for sector, content in ((0, boot), (6, boot), (1, fsinfo), (7, fsinfo)):
            image.seek(sector * 512)
            image.write(content)
        for index, path in enumerate(sorted(files.iterdir())):
            payload = path.read_bytes()
            hashes[path.name] = hashlib.sha256(payload).hexdigest()
            count = (len(payload) + SPC * 512 - 1) // (SPC * 512)
            chain = list(range(next_cluster, next_cluster + count * 17, 17))
            next_cluster = chain[-1] + 17
            if next_cluster > CLUSTERS:
                raise ValueError("Generated assets exceed reserved cluster range")
            entry = index * 32
            stem, extension = path.name.split(".")
            directory[entry:entry + 11] = (stem.ljust(8) + extension).encode("ascii")
            directory[entry + 11] = 0x20
            struct.pack_into("<H", directory, entry + 20, chain[0] >> 16)
            struct.pack_into("<HI", directory, entry + 26, chain[0] & 0xFFFF, len(payload))
            for n, cluster in enumerate(chain):
                struct.pack_into("<I", fat, cluster * 4, chain[n + 1] if n + 1 < count else 0x0FFFFFFF)
                image.seek((DATA_SECTOR + (cluster - 2) * SPC) * 512)
                image.write(payload[n * SPC * 512:(n + 1) * SPC * 512])
        image.seek(DATA_SECTOR * 512)
        image.write(directory)
        for sector in (RESERVED, RESERVED + FAT_SECTORS):
            image.seek(sector * 512)
            image.write(fat)
    verified = verify_image(target, hashes)
    report = {"created": datetime.now().isoformat(), "image": str(target), "cluster_bytes": SPC * 512,
              "directory_order": list(hashes), "file_sha256": hashes, "verified_files": verified,
              "note": "Local image only. No physical device was opened or written."}
    (out / "manifest.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / "work" / ("media_" + datetime.now().strftime("%Y%m%d_%H%M%S")))
    args = parser.parse_args()
    resolved = args.output.resolve()
    if not resolved.is_relative_to(REPO / "work"):
        parser.error("Output must be a new directory beneath work")
    print(f"Verified local FAT32 image: {prepare(resolved)}")


if __name__ == "__main__":
    main()
