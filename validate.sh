#!/bin/bash
# Three-phase validation of the FP4+DFlash unified build.
# Runs binaries inside the SDK image they were linked against.
cd /home/steve/hal0-work/rocmfp4-llama || exit 1
IMG=docker.io/kyuz0/amd-strix-halo-toolboxes:rocm7-nightlies
RUN="podman run --rm --device /dev/kfd --device /dev/dri --group-add keep-groups \
 -v /var/lib/hal0/models:/models:ro -v /home/steve/hal0-work/rocmfp4-llama:/src"
LEAN_QWEN=/var/lib/hal0/models/local/qwen36-35b-mtp/Qwen3.6-35B-A3B-Q4_0_ROCMFP4_STRIX_LEAN.gguf

echo "=== 0/3 re-pull Qwen3.6 LEAN for the combo (background) $(date +%T) ==="
( /home/steve/hal0-work/upload-venv/bin/hf download \
    gsrunion/Qwen3.6-35B-A3B-ROCmFP4-STRIX_LEAN-GGUF \
    Qwen3.6-35B-A3B-Q4_0_ROCMFP4_STRIX_LEAN.gguf \
    --local-dir /var/lib/hal0/models/local/qwen36-35b-mtp > repull-lean.log 2>&1 \
  && echo LEAN-REPULL-OK ) &
PULL_PID=$!

echo "=== 1/3 FP4 regression: Nano STRIX_LEAN bench (expect ~82.5) $(date +%T) ==="
$RUN --entrypoint /src/build-dflash/bin/llama-bench $IMG \
  -m /models/local/nemotron3-nano/Nemotron-Nano-3-30B-A3B-Q4_0_ROCMFP4_STRIX_LEAN.gguf \
  -fa 1 --mmap 0 2>&1 | grep -E '^\||build:' | tail -4

timing_probe () {  # $1 label — three server timing calls against :9198
  python3 - "$1" <<'EOF'
import json, sys, time, urllib.request
label = sys.argv[1]
deadline = time.time() + 600
while True:
    try:
        urllib.request.urlopen("http://127.0.0.1:9198/health", timeout=5); break
    except Exception:
        if time.time() > deadline: print(f"{label}: SERVER NEVER READY"); sys.exit(1)
        time.sleep(5)
for name, p in [("code","Write a Python class implementing an LRU cache with get, put, delete, docstrings and a usage example."),
                ("reason","List the first 25 primes, then explain and trace the Sieve of Eratosthenes for n=50."),
                ("prose","Write a detailed two-paragraph explanation of how tides work, for a curious 12-year-old.")]:
    body = json.dumps({"prompt": p, "n_predict": 640, "temperature": 0,
                       "cache_prompt": False}).encode()
    r = urllib.request.Request("http://127.0.0.1:9198/completion", data=body,
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=600) as resp: d = json.loads(resp.read())
    t = d.get("timings", {})
    print(f"RESULT {label} {name}: {t.get('predicted_per_second',0):.1f} tok/s "
          f"(draft_n={t.get('draft_n')} accepted={t.get('draft_n_accepted')})", flush=True)
EOF
}

echo "=== 2/3 DFlash regression: UD-Q4_K_XL + draft (expect ~90) $(date +%T) ==="
$RUN -d --replace --name fp4dflash-test -p 127.0.0.1:9198:8080 \
  --entrypoint /src/build-dflash/bin/llama-server $IMG \
  -m /models/local/qwen36-35b-mtp/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --model-draft /models/local/qwen36-35b-mtp/dflash/Qwen3.6-35B-A3B-DFlash-BF16.gguf \
  --spec-type draft-dflash --spec-draft-n-max 6 \
  --host 0.0.0.0 --port 8080 -ngl 999 -fa on --jinja -c 32768
timing_probe phase2-kquant-dflash
podman rm -f fp4dflash-test >/dev/null 2>&1

echo "=== waiting for LEAN re-pull $(date +%T) ==="
wait $PULL_PID

echo "=== 3/3 THE COMBO: STRIX_LEAN + DFlash (hypothesis ~120) $(date +%T) ==="
$RUN -d --replace --name fp4dflash-test -p 127.0.0.1:9198:8080 \
  --entrypoint /src/build-dflash/bin/llama-server $IMG \
  -m /models/local/qwen36-35b-mtp/Qwen3.6-35B-A3B-Q4_0_ROCMFP4_STRIX_LEAN.gguf \
  --model-draft /models/local/qwen36-35b-mtp/dflash/Qwen3.6-35B-A3B-DFlash-BF16.gguf \
  --spec-type draft-dflash --spec-draft-n-max 6 \
  --host 0.0.0.0 --port 8080 -ngl 999 -fa on --jinja -c 32768
timing_probe phase3-COMBO
echo "=== combo quality sanity ==="
curl -s http://127.0.0.1:9198/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Four people (Ann, Ben, Cy, Dee) sit in chairs 1-4. Ann is immediately left of Ben. Cy is in chair 1 or 4. Dee is immediately left of Cy. Ben is in a lower chair than Dee. Give the seating."}],"temperature":0,"max_tokens":3000}' \
  | python3 -c "import json,sys; print('SANITY:', (json.load(sys.stdin)['choices'][0]['message'].get('content') or '')[-200:])"
podman rm -f fp4dflash-test >/dev/null 2>&1
echo VALIDATION-DONE
