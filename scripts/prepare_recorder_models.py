"""Stage the pinned offline recording models in the iPhone app resources."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "segmentation.int8.onnx": (
        "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.int8.onnx",
        "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d",
    ),
    "speaker-embedding.zh.onnx": (
        "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/8be2a75c9ed7a590538b268e46fbb65e1aa9d208/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
        "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b",
    ),
    "qwen3-asr/conv_frontend.onnx": (
        "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a/conv_frontend.onnx",
        "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e",
    ),
    "qwen3-asr/encoder.int8.onnx": (
        "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a/encoder.int8.onnx",
        "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9",
    ),
    "qwen3-asr/decoder.int8.onnx": (
        "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a/decoder.int8.onnx",
        "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771",
    ),
    "qwen3-asr/tokenizer/merges.txt": (
        "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a/tokenizer/merges.txt",
        "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
    ),
    "qwen3-asr/tokenizer/tokenizer_config.json": (
        "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a/tokenizer/tokenizer_config.json",
        "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c",
    ),
    "qwen3-asr/tokenizer/vocab.json": (
        "https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a/tokenizer/vocab.json",
        "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
    ),
}
QWEN_REVISION = "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a"
RESOURCES = ROOT / "VenusTools/iOS/Resources/RecorderModels"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(cache, name, url, sha256):
    path = cache / name
    if path.is_file() and digest(path) == sha256:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".partial")
    subprocess.run(
        ["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
         "--max-time", "3600", "--output", str(temporary), url],
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
    for obsolete in ("zipformer-model.int8.onnx", "zipformer-tokens.txt"):
        (RESOURCES / obsolete).unlink(missing_ok=True)
    paths = []
    for name in ("segmentation.int8.onnx", "speaker-embedding.zh.onnx"):
        path = RESOURCES / name
        shutil.copyfile(sources[name], path)
        paths.append(path)
    qwen_dir = RESOURCES / "Qwen3ASR06B"
    qwen_dir.mkdir(parents=True, exist_ok=True)
    for name in SOURCES:
        if not name.startswith("qwen3-asr/"):
            continue
        relative_path = name.removeprefix("qwen3-asr/")
        destination = qwen_dir / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sources[name], destination)
    (qwen_dir / "verified").write_text(QWEN_REVISION, encoding="utf-8")
    paths.extend(qwen_dir / name for name in (
        "conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx",
        "tokenizer/merges.txt", "tokenizer/tokenizer_config.json", "tokenizer/vocab.json", "verified",
    ))
    total = sum(path.stat().st_size for path in paths)
    diarization_total = sum(path.stat().st_size for path in paths[:2])
    if diarization_total >= 100_000_000:
        raise ValueError(f"Diarization models exceed the 100 MB limit: {diarization_total} bytes")
    print(f"Staged {len(paths)} offline recording model files ({total:,} bytes, including Qwen3 ASR).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=ROOT / ".models/recorder-sources")
    prepare(parser.parse_args().cache)
