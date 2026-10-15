"""Package the tested plugin files as an UNSIGNED Openplanet .op (ZIP archive).

For local Developer Mode tests only. Upload to Plugin Manager requires a separate
eligibility decision and Openplanet review/signature; this command never uploads.
"""

import argparse
from pathlib import Path
import os
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


PLUGIN = Path(__file__).resolve().parent.parent / "plugin"
FILES = (
    "info.toml", "Main.as", "Catalog.as", "Medals.as", "Window.as", "UME.as",
    "MenuBadges.as", "Positions.as", "RaceHud.as", "catalog/catalog-v2.json", "catalog/fall-2026-order.json",
    "assets/platinum.png", "assets/emerald.png", "assets/diamond.png",
)


def package(output: Path) -> None:
    if not output.parent.is_dir() or output.suffix.lower() != ".op":
        raise ValueError("output must be a .op in an existing directory")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".progressive-", suffix=".zip", delete=False) as stream:
            temporary = Path(stream.name)
        with ZipFile(temporary, "w", compression=ZIP_DEFLATED, compresslevel=6) as archive:
            for relative in FILES:
                path = PLUGIN / relative
                if not path.is_file() or path.is_symlink() or path.stat().st_size > 8_000_000:
                    raise ValueError(f"missing, linked or excessive plugin file: {relative}")
                item = ZipInfo(relative, date_time=(2026, 10, 14, 0, 0, 0))
                item.compress_type = ZIP_DEFLATED
                item.external_attr = 0o100644 << 16
                archive.writestr(item, path.read_bytes(), compress_type=ZIP_DEFLATED, compresslevel=6)
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=PLUGIN.parent / "ProgressiveMedals-0.3.0-dev.op")
    arguments = parser.parse_args()
    package(arguments.output)
    print(f"Unsigned local package: {arguments.output}")
