#!/usr/bin/env python3
"""
Assemble a release package for Analogue Pocket SD card deployment.
Generates bitstream.rbf_r (bit-reversed per APF requirement) and structures:
  Release/
    sd_card/
      Cores/danimanx.SpaceFish/
        bitstream.rbf_r
        core.json
        data.json
        video.json
        audio.json
        input.json
        interact.json
        variants.json
        icon.bin
        info.txt
      Platforms/
        taitof3.json
        _images/
          taitof3.bin
      Assets/taitof3/
        common/
          README.txt
        danimanx.SpaceFish/
          Darius Gaiden - Silver Hawk.json
          ...

Also produces a ready-to-extract ZIP archive: Release/SpaceFish_Pocket_v1.0.1.zip
"""

import os
import sys
import shutil
import zipfile
import argparse

def reverse_bits(data: bytes) -> bytes:
    table = bytes(int('{:08b}'.format(b)[::-1], 2) for b in range(256))
    return data.translate(table)

def main():
    parser = argparse.ArgumentParser(description="Package SpaceFish core for Analogue Pocket")
    parser.add_argument("--rbf", default="src/fpga/output_files/pocket_spacefish.rbf", help="Path to compiled .rbf bitstream")
    parser.add_argument("--apf", default="apf", help="Path to APF template tree")
    parser.add_argument("--out", default="Release", help="Output directory")
    parser.add_argument("--version", default="v1.0.1", help="Release version tag")
    args = parser.parse_args()

    here = os.path.abspath(os.path.dirname(__file__) + "/..")
    rbf_path = os.path.join(here, args.rbf)
    apf_path = os.path.join(here, args.apf)
    out_path = os.path.join(here, args.out)
    sd_path = os.path.join(out_path, "sd_card")

    os.makedirs(sd_path, exist_ok=True)

    # 1. Copy APF template
    print(f"Copying APF structure from {apf_path}...")
    for item in ["Cores", "Platforms", "Assets"]:
        src_item = os.path.join(apf_path, item)
        dst_item = os.path.join(sd_path, item)
        if os.path.exists(dst_item):
            shutil.rmtree(dst_item)
        shutil.copytree(src_item, dst_item)

    # 2. Convert RBF to bit-reversed RBF_R if RBF exists
    core_dir = os.path.join(sd_path, "Cores", "danimanx.SpaceFish")
    rbf_r_path = os.path.join(core_dir, "bitstream.rbf_r")
    if os.path.isfile(rbf_path):
        print(f"Converting {rbf_path} -> {rbf_r_path} (bit reversal)...")
        with open(rbf_path, "rb") as fin:
            raw_rbf = fin.read()
        rbf_r_data = reverse_bits(raw_rbf)
        with open(rbf_r_path, "wb") as fout:
            fout.write(rbf_r_data)
        print(f"Wrote bitstream.rbf_r ({len(rbf_r_data)} bytes)")
    else:
        print(f"Notice: RBF bitstream not found at {rbf_path}. Creating placeholder if not present.")
        if not os.path.exists(rbf_r_path):
            with open(rbf_r_path, "wb") as f:
                f.write(b"")

    # 3. Add README.txt in Assets/taitof3/common/
    common_readme = os.path.join(sd_path, "Assets", "taitof3", "common", "README.txt")
    os.makedirs(os.path.dirname(common_readme), exist_ok=True)
    with open(common_readme, "w") as f:
        f.write(
            "Taito F3 ROM files (.rom) must be placed in this folder (Assets/taitof3/common/).\n"
            "Build .rom files using tools/build_rom.py from your verified MAME 0.288 romset.\n"
            "Examples:\n"
            "  Assets/taitof3/common/dariusg.rom\n"
            "  Assets/taitof3/common/rayforce.rom\n"
            "  Assets/taitof3/common/elvactr.rom\n"
            "  Assets/taitof3/common/bublbob2.rom\n"
        )

    # 4. Create ZIP archive
    zip_filename = f"SpaceFish_Pocket_{args.version}.zip"
    zip_path = os.path.join(out_path, zip_filename)
    print(f"Creating ZIP archive {zip_path}...")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, _, files in os.walk(sd_path):
            for file in files:
                abs_file = os.path.join(root, file)
                rel_file = os.path.relpath(abs_file, sd_path)
                zipf.write(abs_file, rel_file)

    print(f"Release package assembled successfully at: {zip_path}")

if __name__ == "__main__":
    main()
