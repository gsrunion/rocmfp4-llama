#!/bin/bash
# Phase 4: cross-model draft experiment — Ornith-35B (Qwen3.5-MoE lineage)
# as DFlash target using the Qwen3.6-A3B draft. Two outcomes matter:
# geometry mismatch (fails to load: answered in seconds) or an acceptance
# number (decides if draft recycling is viable for the Qwen family tree).
cd /home/steve/hal0-work/rocmfp4-llama || exit 1
IMG=docker.io/kyuz0/amd-strix-halo-toolboxes:rocm7-nightlies

podman run --rm -d --replace --name ornith-cross-test -p 127.0.0.1:9196:8080 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  -v /var/lib/hal0/models:/models:ro -v /home/steve/hal0-work/rocmfp4-llama:/src \
  --entrypoint /src/build-dflash/bin/llama-server $IMG \
  -m /models/local/Ornith-1.0-35B-ROCmFP4-STRIX_LEAN.gguf \
  --model-draft /models/local/qwen36-35b-mtp/dflash/Qwen3.6-35B-A3B-DFlash-BF16.gguf \
  --spec-type draft-dflash --spec-draft-n-max 6 \
  --host 0.0.0.0 --port 8080 -ngl 999 -fa on --jinja -c 32768

python3 - <<'EOF'
import json, subprocess, sys, time, urllib.request
deadline = time.time() + 420
while True:
    try:
        urllib.request.urlopen("http://127.0.0.1:9196/health", timeout=5); break
    except Exception:
        # if the container already died, capture why and bail
        alive = subprocess.run(["podman","ps","-q","-f","name=ornith-cross-test"],
                               capture_output=True, text=True).stdout.strip()
        if not alive:
            print("CROSS-TEST: server died during load (likely geometry/tokenizer mismatch):")
            subprocess.run(["podman","logs","--tail","6","ornith-cross-test"])
            sys.exit(1)
        if time.time() > deadline:
            print("CROSS-TEST: never ready"); sys.exit(1)
        time.sleep(5)
for name, p in [("code","Write a Python class implementing an LRU cache with get, put, delete, docstrings and a usage example."),
                ("reason","List the first 25 primes, then explain and trace the Sieve of Eratosthenes for n=50.")]:
    body = json.dumps({"prompt": p, "n_predict": 512, "temperature": 0,
                       "cache_prompt": False}).encode()
    r = urllib.request.Request("http://127.0.0.1:9196/completion", data=body,
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=600) as resp: d = json.loads(resp.read())
    t = d.get("timings", {})
    dn, da = t.get("draft_n") or 0, t.get("draft_n_accepted") or 0
    print(f"CROSS {name}: {t.get('predicted_per_second',0):.1f} tok/s, "
          f"acceptance {100*da/dn if dn else 0:.0f}% ({da}/{dn})", flush=True)
EOF
podman rm -f ornith-cross-test >/dev/null 2>&1
echo PHASE4-DONE
