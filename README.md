# viboplr-whisper-cpp

The `whisper-cli` and models that the [Vibo](https://github.com/outcast1000/viboplr) Whisper plugin ([viboplr-whisper](https://github.com/outcast1000/viboplr-whisper)) runs: self-contained builds of [whisper.cpp](https://github.com/ggml-org/whisper.cpp) from a pinned source, for macOS arm64 and Windows x64.

whisper.cpp's own "latest" release has no binaries and there is no command-line build for macOS, so Vibo can't install it from there. This repo builds one and publishes it where Vibo's managed-tool installer looks: `releases/latest`, with a `SHA256SUMS` file.

## What is here

| File | What it is |
|---|---|
| `sources.txt` | The whisper.cpp tag, the commit it must resolve to, and the recipe revision. |
| `build.sh` | The recipe. `./build.sh build` clones, builds and packages into `$WHISPER_WORK/out` (default `./work/out`). `./build.sh version` prints the version it would build. |
| `models.txt` | The ggml models copied to a `models-<N>` release. |
| `.github/workflows/build.yml` | Builds both platforms, checks each binary depends on nothing but the OS, reports its own version and transcribes a sample, and publishes on request. |
| `.github/workflows/models.yml` | Copies the models from Hugging Face, checked against Hugging Face's recorded sha256. |

- **macOS arm64**: Metal with the shader library embedded, Accelerate, deployment target 13.3, CPU code limited to what an M1 has.
- **Windows x64**: MSVC, CPU (AVX2/FMA/F16C), static C runtime.

## Versions

A build's version is `<whisper.cpp version>-<build number>-<recipe rev>`, e.g. `1.9.6-5907-1`. It is compiled into the binary (`whisper-cli --version` prints `whisper.cpp version: 1.9.6-5907-1`) and the release is tagged `v1.9.6-5907-1`. Vibo compares the two to decide whether an update exists, so they must match.

To build a newer whisper.cpp, set `WHISPER_TAG` / `WHISPER_COMMIT` in `sources.txt` (`git ls-remote https://github.com/ggml-org/whisper.cpp refs/tags/bNNNN`). To publish a recipe change with the same whisper.cpp, bump `RECIPE_REV`.

```sh
gh workflow run build.yml --repo outcast1000/viboplr-whisper-cpp -f publish=true
gh workflow run models.yml --repo outcast1000/viboplr-whisper-cpp -f tag=models-1
```

Nothing is ever overwritten: publishing a tag that exists fails the run. A models release is a prerelease and never "latest", so it can't shadow the binaries.

## License

MIT for the scripts here. whisper.cpp and the ggml models are MIT, © the ggml authors.
