# Model scan, ML-BOM and model signing

SecOps plan Step 26 (issue #104): a serialized model is a supply-chain artefact like any dependency. Pickle, PyTorch `.pt`/`.pth`, Keras `.h5`/`.keras` and TensorFlow SavedModel files execute code on load. `model-scan.yml` scans every model in the tree with [modelscan](https://github.com/protectai/modelscan), verifies [Sigstore model-signing](https://github.com/sigstore/model-transparency) signatures, enforces the hash pin for models the code loads at runtime, and writes a CycloneDX ML-BOM that also lists the MCP servers, skills and agents of the repository, so one document covers models, tools and servers (Step 26 Advanced).

## Policy

- A model loaded at runtime (pulled from a hub, an object store or an image layer) is **pinned by hash and listed in the ML-BOM**: an entry in `models.json` with `url`, `source`, `version` and `sha256`. An entry without `sha256` fails the PR. The loading code compares the downloaded file against that hash before use.
- A model committed to the tree is scanned on every PR; a `CRITICAL` or `HIGH` finding (code execution on load) fails it by default (`fail-on-severity`).
- Weights produced by a Sparkgeo workflow are signed with `model_signing` in that workflow (keyless, the workflow identity); consuming repositories verify with `verify-signature: true` and the signing workflow's identity. `require-signature: true` once every model in the tree is signed.
- Agent code shipped from a repository (actions, workflows, skills) gets SLSA provenance through `build-provenance.yml` (#64); this gate does not repeat that.

## What runs

| Step | Tool | Notes |
|---|---|---|
| Scan | `modelscan` 0.8.8 via `pipx run` over `paths` (default: the repository root) | extensions modelscan supports: pickle, PyTorch, numpy, Keras, H5 (`h5py` extra); SavedModel directories need `extras: tensorflow,h5py` (large install), otherwise they are reported as a scan error |
| Report | [`report.py`](../.github/actions/modelscan/report.py) | lists every model file (`.pkl .pickle .pt .pth .h5 .hdf5 .keras .bin .safetensors .onnx .ckpt .joblib .npy .npz .gguf`) and SavedModel directory with its SHA-256, applies the severity gate, the manifest pins and the signature checks, writes the ML-BOM |
| Verify | `model_signing verify sigstore` (or `key` with a PEM public key, for self-hosted signing and the tests) | per model with a sibling `<model>.sig`; a failed verification is an error; an unsigned model is a warning, an error with `require-signature` |
| Upload | `actions/upload-artifact` | `sbom/mlbom.cdx.json` as the `mlbom` artefact; same `sbom/` directory as the syft SBOM from `sbom-generate.yml` (#62), so a release step that uploads `sbom/*` ships both |

Severity bands come from modelscan: `CRITICAL` (operators that execute code: `exec`, `eval`, `os`, `subprocess`, `socket`, …), `HIGH` (operators that reach the network or filesystem without executing code), `MEDIUM` (unknown operators, Keras `Lambda` layers), `LOW` (none today).

## `models.json`

```json
{
  "models": [
    {
      "name": "classifier",
      "path": "models/classifier.pkl",
      "source": "https://github.com/sparkgeo/ml-training/releases/tag/v3.2.0",
      "version": "3.2.0",
      "sha256": "…",
      "license": "Apache-2.0"
    },
    {
      "name": "embedder",
      "url": "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/<commit>/model.safetensors",
      "source": "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2",
      "version": "<commit>",
      "sha256": "…"
    }
  ]
}
```

A `path` entry describes a file in the tree: its `sha256` must equal the file's, and the entry's name, version, source and licence go into the ML-BOM component. A `url` entry describes a model fetched at runtime: it appears in the ML-BOM with `sparkgeo:loaded-at-runtime: true` and its hash. Models in the tree without an entry are still scanned and listed, with the hash as version and no source.

## ML-BOM

`sbom/mlbom.cdx.json`, CycloneDX 1.6. Components:

| Component | `type` | From | Identity |
|---|---|---|---|
| model in the tree | `machine-learning-model` | discovery plus `models.json` | SHA-256 of the file (a SavedModel directory: SHA-256 over its sorted relative paths and file hashes); properties `sparkgeo:path`, `sparkgeo:signed`, `sparkgeo:modelscan`, `sparkgeo:signature-verified` |
| model loaded at runtime | `machine-learning-model` | `models.json` `url` entries | the pinned SHA-256; `externalReferences` distribution URL |
| MCP server | `application` | `.mcp-scan.lock` (#103) | the tool-description hash; property `sparkgeo:mcp-config` |
| skill or plugin manifest | `file` | `.mcp-scan.lock` | file hash |
| agent | `application` | active rows of `docs/ai-agents.md` (#102) | config path, class, risk tier, owner and kill switch as properties |

## Signing

In the workflow that produces the weights (`permissions: id-token: write`):

```bash
pipx run --spec model-signing==1.1.1 model_signing sign models/classifier.pkl --signature models/classifier.pkl.sig
```

The signature is a Sigstore bundle whose certificate names the workflow: identity `https://github.com/<org>/<repo>/.github/workflows/<file>.yml@refs/heads/main`, issuer `https://token.actions.githubusercontent.com`. Commit or publish `.sig` next to the model. Consumers verify:

```yaml
jobs:
  model-scan:
    permissions:
      contents: read
    uses: sparkgeo/github-actions/.github/workflows/model-scan.yml@<SHA>
    with:
      actions-ref: <SHA>   # same SHA as above
      verify-signature: true
      signature-identity: https://github.com/sparkgeo/ml-training/.github/workflows/train.yml@refs/heads/main
      # require-signature: true   # once every model is signed
      # extras: tensorflow,h5py   # SavedModel directories
```

A directory model (SavedModel) is signed and verified as a directory: `model_signing sign tf/savedmodel --signature tf/savedmodel.sig`.

## Tested

[`tests/modelscan/run.sh`](../tests/modelscan/run.sh) runs modelscan over a fixture repository with a malicious pickle (`os.system` on load), a safe pickle, a safetensors file, a SavedModel directory and a key-signed pickle, then checks the severity gate at each threshold, key verification of the signed model, a tampered copy, `require-signature`, the manifest pins, and the ML-BOM contents down to the MCP server, skill and agent components. The CI job runs it, then the composite on this repository (no models) and asserts an empty ML-BOM.
