# Multi-Model OVMS Implementation + OpenClaw Integration

## Intel Arc 140T (Xe2) Optimized — P14s Edition

**Document version:** 2025-03 (post-planning session)
**Status:** Implementation plan finalized, Phase 1 ready to begin
**GitHub repo:** [BigDogAgent/ovms-openclaw](https://github.com/BigDogAgent/ovms-openclaw)
**GitHub project:** ovms-openclaw integration (27 issues tracked)

---

## Context & Constraints

- **Host:** Lenovo ThinkPad P14s Gen 6, Aurora Linux (immutable Fedora 43 KDE Plasma)
- **GPU:** Intel Arc 140T (Xe2 iGPU), 8 GB shared VRAM
- **Container runtime:** Rootless Podman (no Docker)
- **Serving stack:** OpenVINO Model Server (OVMS) replaces previous `ollama-ov` single-model setup
- **Gateway:** OpenClaw running on Lenovo X1 Yoga.
- **Network:** All systems are hosted behind a OPNsense firewall. P14s is on network: "NAT" (192.168.10.0/24), X1 Yoga is on network: "BOT" (192.168.20.0/24). Firewall rules will limit access from BOT network to NAT network.
- **Immutability note:** Build tooling runs inside a `fedora:43` Distrobox (`openvino-box`); host packages via `rpm-ostree` only where necessary
- **Quadlet:** All Podman run commands must remain Quadlet-compatible; systemd service definition is deferred to Phase 6 but must not be blocked by earlier decisions

---

## Core Concept

Instead of running one container per model:

- ❌ One container = one model
- ✅ One container = multiple models (dynamic switching via API)

This enables:

- Multi-agent workflows
- Dynamic routing by role
- Model load/unload without container restart
- No container restarts for model switching

---

## Architecture

```
OpenClaw (OCI ARM64, WireGuard)
    ↓
OVMS container (P14s, rootless Podman)
    ↓
Intel Arc 140T iGPU + system RAM
```

---

## Model Source

All models are sourced from the OpenVINO-optimized HuggingFace collection:
**https://huggingface.co/OpenVINO/models?search=qwen3**

All models are pre-converted to OpenVINO IR format (`openvino_model.xml` + `openvino_model.bin`). No local conversion required.

---

## Model Directory Structure

```
~/ovms/models/
├── qwen3-8b-int4/
│   └── 1/
│       ├── openvino_model.xml
│       └── openvino_model.bin
├── qwen3-30b-int4/
│   └── 1/
├── qwen3-coder-30b-int4/
│   └── 1/
├── qwen3-30b-int8/
│   └── 1/
└── qwen3-reranker/
    └── 1/
```

---

## OVMS Container Image

**Pinned tag:** `docker.io/openvino/model_server:2026.0-gpu`

Rationale:

- `-gpu` is the canonical image for hardware-accelerated inference on Arc iGPU
- `-py` adds a Python serving layer not needed for this use case
- Both `-gpu` and `-py` support CPU/iGPU/dGPU/NPU in the 2026.0 release
- Version is pinned (not `latest`) for reproducibility

---

## config.json

> **Note:** The `plugin_config` blocks below represent the current best-known configuration.
> Correct LLM pipeline config vs. standard IR config will be validated and refined in Phase 4.
> The reranker model uses standard IR serving (single forward pass), not the LLM pipeline.

```json
{
  "model_config_list": [
    {
      "config": {
        "name": "qwen-fast",
        "base_path": "/models/qwen3-8b-int4",
        "target_device": "GPU",
        "plugin_config": {
          "CACHE_DIR": "/models/.cache",
          "NUM_STREAMS": 1,
          "PERFORMANCE_HINT": "LATENCY"
        }
      }
    },
    {
      "config": {
        "name": "qwen-main",
        "base_path": "/models/qwen3-30b-int4",
        "target_device": "GPU",
        "plugin_config": {
          "CACHE_DIR": "/models/.cache",
          "NUM_STREAMS": 1,
          "PERFORMANCE_HINT": "LATENCY"
        }
      }
    },
    {
      "config": {
        "name": "qwen-coder",
        "base_path": "/models/qwen3-coder-30b-int4",
        "target_device": "GPU",
        "plugin_config": {
          "CACHE_DIR": "/models/.cache",
          "NUM_STREAMS": 1,
          "PERFORMANCE_HINT": "LATENCY"
        }
      }
    },
    {
      "config": {
        "name": "qwen-precision",
        "base_path": "/models/qwen3-30b-int8",
        "target_device": "GPU",
        "plugin_config": {
          "CACHE_DIR": "/models/.cache",
          "NUM_STREAMS": 1,
          "PERFORMANCE_HINT": "LATENCY"
        }
      }
    },
    {
      "config": {
        "name": "qwen-reranker",
        "base_path": "/models/qwen3-reranker",
        "target_device": "CPU"
      }
    }
  ]
}
```

---

## Podman Run Command

> Commit as `ovms/run.sh` in the repo. Must remain Quadlet-compatible.

```bash
#!/bin/bash
podman run \
  --user $(id -u):$(id -g) \
  -d \
  --name ovms \
  -p 8000:8000 \
  --device /dev/dri \
  --device /dev/accel \
  --group-add keep-groups \
  --security-opt label=disable \
  -v ~/ovms/models:/models:rw \
  docker.io/openvino/model_server:2026.0-gpu \
  --config_path /models/config.json \
  --rest_port 8000 \
  --rest_bind_address 0.0.0.0
```

**Removed vs. single-model setup** (not supported or deferred in multi-model mode):

- `--source_model` — not applicable in config.json mode
- `--tool_parser` — under investigation (see Tool Calling section)
- `--reasoning_parser` — under investigation (see Tool Calling section)
- `--enable_tool_guided_generation` — under investigation
- `--cache_size` / `--enable_prefix_caching` — moved to `plugin_config` per model; exact keys to be validated in Phase 4

---

## VRAM Budget Considerations

The Arc 140T shares memory with system RAM).

- 30B INT4  and 30B INT8 models are confirmed to work with acceptable performance.
- Loading all models simultaneously is not the target; **dynamic load/unload is the strategy**
- OVMS supports hot-reload: edit `config.json` → `POST /v1/config/reload` — no container restart needed
- Load/unload strategy (which models stay resident, which load on demand) will be defined in Phase 3 (Issue #15) based on observed data

---

## Dynamic Model Load/Unload

OVMS supports hot-reload without container restart:

```bash
# Edit config.json to add or remove model entries, then:
curl -X POST http://localhost:8000/v1/config/reload
```

- Adding a model entry → loads the model
- Removing a model entry → unloads the model
- Behavior during active inference requests needs testing (Phase 3, Issue #14)

---

## API Endpoints

**List loaded models:**

```bash
curl http://localhost:8000/v1/models
```

**Chat completion (OpenAI-compatible):**

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-main",
    "messages": [{"role": "user", "content": "Your prompt here"}]
  }'
```

> Model is selected per-request via the `"model"` field in the request body.
> The `/v1/models/qwen-main:predict` KServe-style path is **not** used for OpenAI-compatible inference.

---

## OpenClaw Integration

### Model Role Mapping

| Role     | Model name     | Base model           |
| -------- | -------------- | -------------------- |
| planner  | qwen-main      | qwen3-30b-int4       |
| coder    | qwen-coder     | qwen3-coder-30b-int4 |
| fallback | qwen-precision | qwen3-30b-int8       |
| retry    | qwen-fast      | qwen3-8b-int4        |
| reranker | qwen-reranker  | qwen3-reranker       |

> Role-to-model mapping may be adjusted after Phase 2/3 memory observations.

### Network

- OVMS runs on P14s; OpenClaw runs on OCI ARM64 instance
- Connected via WireGuard VPN
- OpenClaw targets: `http://<p14s-wireguard-ip>:8000/v1/chat/completions`
- Port 8000 must not be firewalled on the P14s WireGuard interface

---

## Tool Calling

Status: **under investigation**

In the previous single-model `ollama-ov` setup, tool calling was handled via server-side flags (`--tool_parser`, `--reasoning_parser`). In OVMS multi-model mode these flags are not confirmed as supported.

Possible resolution paths:

1. Tool calling handled via model-side chat template + request-level parameters (no server flag needed)
2. Flags restored in OVMS config if confirmed supported
3. Tool calling logic moves to OpenClaw config/prompt construction

To be resolved in Phase 5, Issue #23.

---

## Retry & Fallback Strategy

| Error type       | Fallback model |
| ---------------- | -------------- |
| Invalid JSON     | qwen-fast      |
| Bad arguments    | qwen-coder     |
| Critical failure | qwen-precision |

Implementation location (OpenClaw agent vs. middleware shim) to be determined in Phase 6 once a working system is available to test against.

---

## Execution Layer

Wrap all executed commands:

```bash
timeout 60 bash -c "<command>"
```

Capture: `stdout`, `stderr`, `exit_code`. Send results back to model for decision-making.

### Safety Rules (draft)

Block list:

- `rm -rf /`
- `mkfs`

Allow list:

- `systemctl`
- `dnf`
- `git`

> Safety rules are a draft. Final implementation deferred to Phase 6 (Issue #25) once actual use cases are observable on a working system.

---

## Validation Loop

1. Call model
2. Validate JSON response
3. Retry with fallback model if invalid
4. Execute command
5. Capture result
6. Send result back to model for verification

---

## Tool Schema

### Universal format

```json
{
  "tool": "string",
  "arguments": {},
  "reasoning": "string",
  "confidence": 0.0
}
```

### Available tools

**run_bash**

```json
{ "command": "string" }
```

**systemctl**

```json
{ "action": "start|stop|restart|status", "service": "string" }
```

**package_manager**

```json
{ "action": "install|update|remove|list-updates", "package": "string" }
```

**git**

```json
{ "action": "clone|pull|push|commit", "repo": "string" }
```

**check_api**

```json
{ "url": "string" }
```

---

## Quadlet Service (deferred — Phase 6)

A rootless Podman Quadlet `.container` unit will be written in Phase 6 (Issue #26) once implementation is confirmed working. The unit will be based on `ovms/run.sh` and will include:

- All device flags from the run command
- Volume mounts and port bindings
- Restart policy
- Health check via `GET /v1/models`
- `loginctl enable-linger` assumed active on host

Commit target: `ovms/ovms.container`

---

## Implementation Phases (Summary)

| Phase | Goal                                                                    | Key issues |
| ----- | ----------------------------------------------------------------------- | ---------- |
| 1     | Minimum working OVMS service — single model, verified inference         | #1–#6      |
| 2     | Multi-model config — all models loaded, individually addressable        | #7–#10     |
| 3     | Dynamic load/unload — hot-reload validated, strategy defined            | #11–#15    |
| 4     | LLM pipeline tuning — correct plugin_config, caching, performance       | #16–#19    |
| 5     | OpenClaw integration — routing, WireGuard, tool calling resolved        | #20–#23    |
| 6     | Resilience & hardening — retry logic, safety rules, Quadlet, monitoring | #24–#27    |

**Approach:** Agile/incremental. Get a minimum working service in Phase 1, extend from there. No big-bang deployment.

**Tracking:** All 27 stories tracked as GitHub Issues in [BigDogAgent/ovms-openclaw](https://github.com/BigDogAgent/ovms-openclaw), managed on the `ovms-openclaw integration` project board.

---

## Advanced: Hot Reload Reference

```bash
# Trigger config reload (add/remove models without restart)
curl -X POST http://localhost:8000/v1/config/reload
```

## Advanced: Performance Config Reference

```json
"plugin_config": {
  "PERFORMANCE_HINT": "LATENCY",
  "NUM_STREAMS": 1,
  "CACHE_DIR": "/models/.cache"
}
```

> `LATENCY` vs `THROUGHPUT` tradeoff to be measured in Phase 4 (Issue #18).
