# Local speech reference

Optional ASR and TTS wrappers matching Voicestack's current speech contracts.
Use them to assemble local endpoints on Apple Silicon macOS with Python 3.12
and Metal/MLX. The apps and phone bridge connect to separately run processes;
they don't install, start or stop these servers.

ASR supports Parakeet GGUF through transcribe.cpp or Voxtral Realtime through
MLX Audio. The TTS gateway adapts a separate Breeze server to the JSON speech
requests used by Voicestack. Models and reference voices are obtained separately.
Review [model terms and dependency revisions](NOTICES.md) first: Gust-MLX has
research/non-commercial and API/service-use restrictions, and the pinned
Parakeet conversion card contains conflicting licence statements.

## Prepare the Python environment

From this directory, with Python 3.12 already installed:

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

Installation downloads dependencies and may compile native code. The direct
versions are pinned; transitive dependencies resolve at install time. No model
weights are included or installed by these commands. Use compatible local model
files in the examples below. Loaders can download files when passed remote model
identifiers; configure their offline mode if needed. Memory requirements depend
on the selected model.

## Speech recognition

Start in its own terminal, replacing the path with your permitted model:

```sh
.venv/bin/python -m speechd.stt_server \
  --backend parakeet --model /path/to/model.gguf \
  --host 127.0.0.1 --port 8446
```

Parakeet returns a whole-utterance final and supports optional live partials.
It loads a second model instance for partials; `--no-partials` disables that
instance. Voxtral streams committed text deltas. To use it, replace the backend
arguments with `--backend voxtral --model /path/to/mlx-snapshot --precision fp16
--model-id YOUR_MODEL_ID --revision YOUR_REVISION`.
Model ID and revision are reported metadata, without weight verification.
`--precision fp16` also casts selected Voxtral parameters.

The WebSocket endpoint is `ws://127.0.0.1:8446/v1/transcribe`. Send binary mono
16 kHz s16le PCM frames, then `{"type":"input_audio.end"}`. Keep the socket open
and append committed `transcript.text` until normal server close code 1000.
An `error` message means failure. Clients requesting `?partials=1` also receive
Parakeet `transcript.partial` snapshots: replace the partial display, then use
the separate final transcript. This is a custom one-utterance protocol; OpenAI
Transcriptions and Realtime clients need a different adapter.

## Speech synthesis

Obtain [Breeze at the documented revision](NOTICES.md#breeze-server) and prepare
its dependencies in a separate environment. Its MLX Audio pin and macOS
dependency overrides differ from this reference. Review and resolve those
requirements before running it; this repository doesn't lock that environment.

With a permitted local Breeze model, run in that separate checkout/environment:

```sh
python -m breeze_infer.api /path/to/breeze-model \
  --host 127.0.0.1 --port 8450 --ws-port disabled \
  --chunk-first 1 --chunk-max 1 --voices-dir /path/to/private/breeze-state
```

Create a private directory with your permitted `reference.wav` and its exact
transcript `reference.txt`. Obtain speaker consent for voice conditioning.
Optional `reference.json` supplies `seed`, `cfg_scale`, `instruction` and `label`.
There are no built-in voices. In a second terminal in this reference directory:

```sh
.venv/bin/python -m speechd.tts_gateway \
  --upstream http://127.0.0.1:8450 \
  --voices /path/to/private/references --state /path/to/private/gateway-state \
  --default-voice reference --host 127.0.0.1 --port 8444
```

Startup registers or replaces references on Breeze, writes gateway state, and
synthesizes warm-up text. Use a dedicated upstream and private state. A JSON
request to `POST /v1/audio/speech` looks like:

```json
{"voice":"default","input":"Hello from the local reference.","response_format":"wav"}
```

`wav` returns a complete mono 24 kHz 16-bit PCM WAV after synthesis. `pcm` streams
headerless audio in the same format. Optional `instructions` maps to Breeze's
instruction field. Only `stream_format: "audio"` is supported; MP3, Opus, SSE
and speed control aren't implemented. Input is limited to 10,000 characters.
The request `model` field is ignored; `--upstream` changes the Breeze address,
and doesn't select another model family.

`GET /v1/voices` lists references, including their transcripts and settings.
`PUT /v1/voices/default` with `{"voice":"reference"}` persists the voice selected
by `default`; explicitly named requests keep their selection. One synthesis
runs at a time, with up to `TTS_MAX_QUEUED` (32) waiting requests and a
`TTS_QUEUE_WAIT_S` (30) deadline. Admission failures return 429. Clients must
handle truncated streams if the upstream fails or the request is cancelled.

## Connect Voicestack

For the [Mac settings](../../macos/config/settings.example.json), use:

```json
{
  "asrUrl": "ws://127.0.0.1:8446/v1/transcribe",
  "ttsUrl": "http://127.0.0.1:8444/v1/audio/speech",
  "ttsModel": "breeze-tts-2",
  "voice": "default",
  "ttsStream": false
}
```

Merge those speech fields into your own settings. The phone uses its bridge's
loopback upstream ports, documented in [iPhone setup](../../ios/SETUP.md).
Its device credential is separate from speech-service credentials; the bridge
doesn't forward arbitrary provider keys. Don't change enrollment or call policy
to configure these servers.

Keep all listeners on loopback. Optional `SPEECHD_STT_API_KEY` and
`SPEECHD_TTS_API_KEY` require Bearer auth on speech requests; the TTS key also
protects default-voice mutation and gateway model administration. Model
administration is unsupported with this pinned Breeze recipe; the retained
gateway forwarding routes require a different compatible upstream. Mac clients
can supply speech keys; the phone bridge needs compatible upstream auth routing.
Health and voice listing are unauthenticated, and there is no TLS or per-user
isolation. Other local users can reach loopback listeners. Keep references,
weights, credentials, state and logs outside the checkout; logs can contain
paths, voice names and upstream error text.

Run each process in the foreground or through a supervisor you configure.
Ctrl-C stops a foreground process. Existing services should retain their own
supervisor and port assignments; don't start duplicates. This reference has no
idle proxy, service installer, Fleet registration or client-settings editor.

## Offline checks

```sh
python3.12 -I -B tests/test_reference.py -v
```

The stdlib fixtures extract selected definitions with AST and use in-memory
stand-ins. They check WAV framing, auth, ASR text delivery, TTS validation,
queueing and cancellation, plus static app/CLI contracts. They don't import
inference libraries, bind sockets or spawn servers. Native inference, dependency
installation, Breeze integration and real-client operation haven't been tested
for this reference. Server startup is an inference operation; don't use it as
a syntax check.

Original wrappers, tests and docs use the repository's [MIT licence](../../LICENSE).
External libraries, server code, models and voices retain the separate terms in
[NOTICES.md](NOTICES.md).
