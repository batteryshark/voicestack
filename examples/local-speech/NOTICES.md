# Dependencies and model terms

The original `speechd` wrappers and fixtures are copyright 2026 batteryshark,
under the repository's [MIT License](../../LICENSE). They are derived from the
sanitized reference at `56472f2002d95851a9b237ccd8a44847322a5dbc`; no upstream
implementations, native binaries, models or media are vendored here.

## Inference libraries

`requirements.txt` retains direct versions from that reference's resolved
environment: aiohttp 3.14.5, NumPy 2.5.4, transcribe-cpp 0.4.0 and MLX Audio's
STT extra at `e66ad2ff4eb96ce1149000187b30370cbcd707aa`. It isn't a transitive
lock. The wrappers target Python 3.12 and Apple Silicon macOS.

* [aiohttp licence](https://github.com/aio-libs/aiohttp/blob/v3.14.5/LICENSE.txt): Apache-2.0.
* [NumPy licence](https://github.com/numpy/numpy/blob/v2.5.4/LICENSE.txt): BSD-3-Clause;
  binary distributions have additional bundled-library notices.
* [transcribe.cpp 0.4.0 source](https://github.com/handy-computer/transcribe.cpp/tree/f1dcd15858c4bbba87ca97862b4e448b2cf15b8f)
  declares MIT. Its bindings select transcribe-cpp-native 0.4.0; native
  ggml/miniz/silero_vad and transitive components carry their own notices.
* [MLX Audio source and MIT licence](https://github.com/Blaizzy/mlx-audio/tree/e66ad2ff4eb96ce1149000187b30370cbcd707aa).
  Voxtral relies on its streaming session feed/close/step and private decoding
  interface. Substituting another revision needs compatibility testing.

The source pins identify the baseline; wheel contents, native builds and the
complete transitive environment haven't been audited here. Preserve the notices
of every dependency you redistribute.

## Breeze server

Obtain [Breeze source at `f1818ec44da33302701718e5fb15267ce1cf5e4f`](https://github.com/Shoofio/breeze-tts2-fast-streaming-api/tree/f1818ec44da33302701718e5fb15267ce1cf5e4f)
separately. Its root licence is Apache-2.0. The gateway requires `/health`, voice
list/delete/upload, multipart `/v1/audio/speech` returning mono 24 kHz s16le,
and `/admin/model/load|unload` for its admin forwarding routes.

Use a separate Python environment. That revision's `requirements.txt` pins MLX
Audio `e1b19b9054bf163f5d812221a54fcc346f1890e9` on macOS arm64. Its
`requirements-mac-overrides.txt` specifies transformers 4.57.3 and
huggingface-hub 0.36.2, overriding declared MLX Audio minima. Review the upstream
requirements and overrides and resolve that dedicated environment yourself.
The wrapper requirements don't install or lock Breeze. The documented CLI shape
hasn't been validated through installation or inference for this reference.

## Models and reference voices

These model revisions identify the source baseline. Obtain permitted weights
separately; metadata flags don't verify loaded files.

* Parakeet: `handy-computer/parakeet-unified-en-0.6b-gguf`, revision
  `7e948f21b7bdbac698d3318db9d350f1096f3b6c`, file
  `parakeet-unified-en-0.6b-Q8_0.gguf`. The pinned
  [conversion card](https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/blob/7e948f21b7bdbac698d3318db9d350f1096f3b6c/README.md)
  labels the conversion CC-BY-4.0 but embeds an NVIDIA model card naming the
  NVIDIA Open Model License Agreement. Resolve those conflicting statements
  against your intended use; don't assume CC-BY-only permission.
* Voxtral: `mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16`, revision
  `9977a0f5c0fce8472083af92957497118adc412b`. Its
  [card](https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16/blob/9977a0f5c0fce8472083af92957497118adc412b/README.md)
  declares Apache-2.0 and identifies `mistralai/Voxtral-Mini-4B-Realtime-2602`
  as its base. Review base-model and tokenizer terms too.
* Breeze model baseline: `Shoof/Gust-MLX`, revision
  `dac391237f6bf6130b1c1d277f0ebc0b886e419e`. Its
  [LICENSE](https://huggingface.co/Shoof/Gust-MLX/blob/dac391237f6bf6130b1c1d277f0ebc0b886e419e/LICENSE),
  [NOTICE](https://huggingface.co/Shoof/Gust-MLX/blob/dac391237f6bf6130b1c1d277f0ebc0b886e419e/NOTICE)
  and [card](https://huggingface.co/Shoof/Gust-MLX/blob/dac391237f6bf6130b1c1d277f0ebc0b886e419e/README.md)
  identify the BreezeBlue Research and Non-Commercial License Agreement v1.0.
  Commercial use requires separate written licensing. Its broad commercial-use
  definition includes production/business operations and API/service functionality;
  don't infer that a personal local API is permitted from the label alone.
  Reference-consent, distribution and notice conditions also apply.

The server's Apache-2.0 licence and the wrappers' MIT licence grant no additional
model-use rights. Reference recordings require permission for voice conditioning,
speaker consent and any required attribution. No recording, transcript, voice,
embedding or model weight is supplied, and no rights to outside voices,
performances or likenesses are granted.
