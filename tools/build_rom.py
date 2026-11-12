#!/usr/bin/env python3
"""Build Analogue Pocket .rom images for Taito F3 (SpaceFish) from MRA and MAME zips.

Each .rom file contains:
  Bytes [0..3]:   Magic "TF3\x01" (4 bytes)
  Bytes [4..5]:   game_cfg (uint16 LE): index 1 in low byte, index 2 in high byte
  Bytes [6..7]:   reserved (uint16 LE, 0)
  Bytes [8..11]:  rom_len (uint32 LE): length of the payload
  Bytes [12..15]: payload CRC32 (uint32 LE)
  Bytes [16..]:   Assembled ROM stream (interleaved per MRA specification)

Usage:
  python3 build_rom.py <game.mra> <roms_dir> <out.rom>
  python3 build_rom.py --all <mras_dir> <roms_dir> <out_dir>
"""

import os
import sys
import argparse
import zipfile
import zlib
import xml.etree.ElementTree as ET

MAGIC = b"TF3\x01"

def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF

def part_bytes(el, by_crc):
    if el.get("crc") is None:
        data = bytes(int(b, 16) for b in (el.text or "").split())
        return data * int(el.get("repeat", "1"))
    c = int(el.get("crc"), 16)
    if c not in by_crc:
        raise KeyError(f"Part CRC {c:08x} not found in zip")
    zf, info = by_crc[c]
    data = zf.read(info)
    off = int(el.get("offset", "0"), 0)
    ln = el.get("length")
    if off or ln is not None:
        end = off + int(ln, 0) if ln is not None else len(data)
        data = data[off:end]
    return data

def assemble_rom_stream(mra_path: str, roms_dir: str) -> tuple[bytes, int]:
    root = ET.parse(mra_path).getroot()

    rom0 = None
    cfg_b0 = 0
    cfg_b1 = 0

    for rom in root.findall("rom"):
        idx = rom.get("index", "0")
        if idx == "0":
            rom0 = rom
        elif idx == "1":
            parts = rom.findall("part")
            if parts and parts[0].text:
                cfg_b0 = int(parts[0].text.strip(), 16)
        elif idx == "2":
            parts = rom.findall("part")
            if parts and parts[0].text:
                cfg_b1 = int(parts[0].text.strip(), 16)

    if rom0 is None:
        raise ValueError(f"No <rom index='0'> in {mra_path}")

    zip_name = rom0.get("zip")
    if not zip_name:
        raise ValueError(f"No zip attribute in rom0 of {mra_path}")

    zip_names = [z.strip() for z in zip_name.split("|") if z.strip()]
    by_crc = {}
    found_any = False
    for zn in zip_names:
        zp = os.path.join(roms_dir, zn)
        if os.path.isfile(zp):
            found_any = True
            zf = zipfile.ZipFile(zp)
            for i in zf.infolist():
                by_crc.setdefault(i.CRC & 0xFFFFFFFF, (zf, i))
    if not found_any:
        raise FileNotFoundError(f"Missing zip file {os.path.join(roms_dir, zip_name)}")

    stream = bytearray()
    for el in rom0:
        if el.tag == "part":
            stream += part_bytes(el, by_crc)
        elif el.tag == "interleave":
            parts = []
            for p in el.findall("part"):
                data = part_bytes(p, by_crc)
                m = p.get("map")
                lanes = {}
                for pos, ch in enumerate(reversed(m)):
                    if ch != "0":
                        lanes[pos] = int(ch) - 1
                parts.append((data, lanes, len(lanes)))
            osize = len(el.findall("part")[0].get("map"))
            groups = len(parts[0][0]) // parts[0][2]
            out = bytearray(osize * groups)
            for data, lanes, n in parts:
                for g in range(groups):
                    for opos, srcidx in lanes.items():
                        out[g * osize + opos] = data[g * n + srcidx]
            stream += out

    game_cfg = (cfg_b1 << 8) | cfg_b0
    return bytes(stream), game_cfg

def build_rom_file(mra_path: str, roms_dir: str, out_path: str):
    stream, game_cfg = assemble_rom_stream(mra_path, roms_dir)
    pl_crc = crc32(stream)
    pl_len = len(stream)

    header = bytearray(16)
    header[0:4] = MAGIC
    header[4:6] = game_cfg.to_bytes(2, "little")
    header[6:8] = (0).to_bytes(2, "little")
    header[8:12] = pl_len.to_bytes(4, "little")
    header[12:16] = pl_crc.to_bytes(4, "little")

    with open(out_path, "wb") as f:
        f.write(header)
        f.write(stream)

    print(f"Built {out_path}: {pl_len + 16} bytes (payload: {pl_len} bytes, cfg: 0x{game_cfg:04X}, CRC: {pl_crc:08X})")

def main():
    parser = argparse.ArgumentParser(description="Build Taito F3 ROM for Analogue Pocket")
    parser.add_argument("mra", nargs="?", help="Path to .mra file")
    parser.add_argument("roms_dir", nargs="?", help="Directory containing MAME zip romsets")
    parser.add_argument("out", nargs="?", help="Output .rom path")
    parser.add_argument("--all", action="store_true", help="Build all MRAs in directory")
    args = parser.parse_args()

    if args.all:
        if not args.mra or not args.roms_dir or not args.out:
            print("Usage with --all: build_rom.py --all <mras_dir> <roms_dir> <out_dir>")
            sys.exit(1)
        os.makedirs(args.out, exist_ok=True)
        for root_dir, _, files in os.walk(args.mra):
            for f in files:
                if f.endswith(".mra"):
                    mra_file = os.path.join(root_dir, f)
                    try:
                        tree = ET.parse(mra_file)
                        setname = tree.getroot().findtext("setname") or os.path.splitext(f)[0]
                        out_rom = os.path.join(args.out, f"{setname}.rom")
                        build_rom_file(mra_file, args.roms_dir, out_rom)
                    except Exception as e:
                        print(f"Skipping {f}: {e}")
    else:
        if not args.mra or not args.roms_dir or not args.out:
            parser.print_help()
            sys.exit(1)
        build_rom_file(args.mra, args.roms_dir, args.out)

if __name__ == "__main__":
    main()
