"""Stage the pinned offline recording models in the iPhone app resources."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[1]
ZIPFORMER = "sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01"
SOURCES = {
    "zipformer.tar.bz2": (
        f"https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{ZIPFORMER}.tar.bz2",
        "b3b309f7ce4a737195fcc6963ea19b0653a7d3401580af5ae0d3e284cbb71f0b",
    ),
    "segmentation.int8.onnx": (
        "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.int8.onnx",
        "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d",
    ),
    "speaker-embedding.zh.onnx": (
        "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/8be2a75c9ed7a590538b268e46fbb65e1aa9d208/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
        "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b",
    ),
}
RESOURCES = ROOT / "VenusTools/iOS/Resources/RecorderModels"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(cache, name, url, sha256):
    path = cache / name
    if path.is_file() and digest(path) == sha256:
        return path
    temporary = path.with_suffix(".partial")
    subprocess.run(
        ["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
         "--max-time", "180", "--output", str(temporary), url],
        check=True,
    )
    if digest(temporary) != sha256:
        raise ValueError(f"Model checksum did not match: {name}")
    temporary.replace(path)
    return path


def prepare(cache):
    cache.mkdir(parents=True, exist_ok=True)
    sources = {name: fetch(cache, name, *source) for name, source in SOURCES.items()}
    RESOURCES.mkdir(parents=True, exist_ok=True)
    paths = []
    with tarfile.open(sources["zipformer.tar.bz2"], "r:bz2") as archive:
        for name in ("model.int8.onnx", "tokens.txt"):
            path = RESOURCES / f"zipformer-{name}"
            with archive.extractfile(f"./{ZIPFORMER}/{name}") as source, path.open("wb") as target:
                shutil.copyfileobj(source, target)
            paths.append(path)
    for name in ("segmentation.int8.onnx", "speaker-embedding.zh.onnx"):
        path = RESOURCES / name
        shutil.copyfile(sources[name], path)
        paths.append(path)
    total = sum(path.stat().st_size for path in paths)
    if total >= 100_000_000:
        raise ValueError(f"Recording models exceed the 100 MB limit: {total} bytes")
    print(f"Staged {len(paths)} offline recording model files ({total:,} bytes).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=ROOT / ".models/recorder-sources")
    prepare(parser.parse_args().cache)
