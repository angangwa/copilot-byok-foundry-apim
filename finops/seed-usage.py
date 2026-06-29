#!/usr/bin/env python3
"""
seed-usage.py — populate App Insights `customMetrics` with a synthetic developer
fleet so the FinOps workbook's per-user analytics light up.

It POSTs pre-aggregated token metrics to the SAME ingestion endpoint the APIM
`llm-emit-token-metric` policy uses, with the SAME schema:
  metric name : Total Tokens | Prompt Tokens | Completion Tokens
  dimensions  : oid, model   (+ developerName + requestedModel, synthetic-only labels)
so the rows are indistinguishable from real gateway telemetry.

For model-router requests the `model` dimension records the SERVED underlying model
(e.g. grok-4-1-fast-reasoning, gpt-5.4-mini) — what the response's `model` field reveals —
and `requestedModel` records "model-router". This lets the dashboard show the routing
split. NOTE: the live gateway can't do this on the metric (the inbound `llm-emit-token-metric`
policy only sees the REQUESTED name "model-router"); real routed-model attribution comes
from the GatewayLlmLogs diagnostic instead. See finops/README.md.

Constraint (measured on this resource): the ingestion endpoint silently drops
records whose timestamp is older than ~60 minutes (rows newer than that are
accepted with their timestamp preserved). So one run seeds a rolling ~55-minute
window of fine-grained buckets. The headline concentration / leaderboard / cost
widgets don't need more history than that; only the trend line is window-bound.
To grow a genuine multi-day trend, run this on a schedule (see seed-loop.sh /
the Container Apps Job in README) so each run appends a fresh "now" slice.

Usage:
  python3 finops/seed-usage.py            # reads config.env for RG / app name
  N_DEVS=80 WINDOW_MIN=55 BUCKET_MIN=5 python3 finops/seed-usage.py

No external dependencies — stdlib + the Azure CLI (for the connection string).
"""
import os, sys, json, math, uuid, random, gzip, subprocess, datetime, urllib.request

# ---- config -----------------------------------------------------------------
APP   = os.environ.get("APPINSIGHTS_APP", "appi-copilot-poc")
RG    = os.environ.get("RG", "rg-copilot-foundry-poc")
N_DEVS     = int(os.environ.get("N_DEVS", "60"))
WINDOW_MIN = int(os.environ.get("WINDOW_MIN", "55"))   # keep < 60 (ingestion drops older)
BUCKET_MIN = int(os.environ.get("BUCKET_MIN", "5"))
SEED       = int(os.environ.get("SEED", "42"))
rnd = random.Random(SEED)

# REQUESTED models — what a developer's client asks for, and the share of devs who favour each.
# (Prompt/context size comes from each developer's CONTEXT PERSONA below; completion is model-driven.)
REQUEST_MODELS = {
    "gpt-4.1":      {"favour": 0.35},   # direct named model
    "gpt-5-mini":   {"favour": 0.25},   # direct named model
    "model-router": {"favour": 0.40},   # routes to one of ROUTER_POOL per request
}
REQUEST_NAMES = list(REQUEST_MODELS)
# Completion-token range for the direct named models.
DIRECT_COMP = {"gpt-4.1": (300, 2500), "gpt-5-mini": (200, 1800)}

# model-router UNDERLYING pool — the served models observed live from this deployment
# (probe: 10 varied prompts -> grok-4-1-fast-reasoning, gpt-5.4-mini, gpt-5-nano, gpt-oss-120b, gpt-5.5).
#   (served model name, routing share, completion-token range)  reasoning models emit more.
ROUTER_POOL = [
    ("grok-4-1-fast-reasoning", 0.42, (400, 3000)),
    ("gpt-5.4-mini-2026-03-17", 0.20, (250, 2200)),
    ("gpt-5-nano-2025-08-07",   0.16, (150, 1200)),
    ("gpt-oss-120b",            0.12, (300, 2400)),
    ("gpt-5.5-2026-04-24",      0.10, (500, 4000)),
]

# Context personas — how big a developer's prompts (context windows) tend to be, and how much
# of that context is cache-eligible (stable prefix reused across agent steps). Long-context
# "big-repo / agentic" devs both send larger prompts AND hit the cache far more.
#   (share, prompt-size lognormal (mu, sigma), cache-affinity range)
CONTEXT_PERSONAS = [
    ("short",     0.60, (math.log(14000),  0.70), (0.05, 0.25)),
    ("medium",    0.24, (math.log(80000),  0.55), (0.25, 0.50)),
    ("long",      0.13, (math.log(320000), 0.45), (0.50, 0.78)),
    ("very-long", 0.03, (math.log(760000), 0.30), (0.62, 0.90)),
]
PROMPT_MIN, PROMPT_MAX, CACHE_MIN_PROMPT = 300, 1_000_000, 1500

FIRST = ["Ada","Alan","Grace","Linus","Ken","Margaret","Dennis","Barbara","Edsger",
         "Donald","Radia","Tim","Brian","Vint","Leslie","Katherine","Guido","Bjarne",
         "James","Anders","Yukihiro","Rich","Joe","Evan","Rasmus","Brendan","John",
         "Carol","Frances","Shafi","Sophie","Hedy","Adele","Annie","Mary","Jean"]
LAST  = list("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

# ---- developer fleet: lognormal activity weights => Pareto-like concentration -
def make_devs(n):
    devs = []
    used = set()
    for i in range(n):
        fn = FIRST[i % len(FIRST)]
        li = LAST[(i // len(FIRST) + i) % len(LAST)]
        name = f"{fn} {li}."
        while name in used:
            li = rnd.choice(LAST); name = f"{fn} {li}."
        used.add(name)
        # heavy right tail: a few power users dominate (lognormal => Pareto-like)
        weight = math.exp(rnd.gauss(0.0, 1.45))
        # each dev favours one model but mixes in others
        primary = _weighted_choice({m: REQUEST_MODELS[m]["favour"] for m in REQUEST_NAMES})
        mix = {m: (0.7 if m == primary else 0.15) * rnd.uniform(0.6, 1.4) for m in REQUEST_NAMES}
        s = sum(mix.values()); mix = {m: v / s for m, v in mix.items()}
        # context persona => prompt-size distribution + cache affinity
        persona, _, ctx_ln, caff = _weighted_choice_t(CONTEXT_PERSONAS)
        cache_aff = rnd.uniform(*caff)
        oid = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"copilot-dev-{i}-{name}"))
        devs.append({"oid": oid, "name": name, "weight": weight, "mix": mix,
                     "persona": persona, "ctx_ln": ctx_ln, "cache_aff": cache_aff})
    return devs

def _weighted_choice_t(rows):
    # rows: (name, share, ...extra). Returns the whole tuple, chosen by share.
    r = rnd.uniform(0, sum(x[1] for x in rows)); upto = 0
    for row in rows:
        upto += row[1]
        if r <= upto:
            return row
    return rows[-1]

def _weighted_choice(d):
    r = rnd.uniform(0, sum(d.values())); upto = 0
    for k, v in d.items():
        upto += v
        if r <= upto:
            return k
    return next(iter(d))

def _router_pick():
    # choose a served underlying model for a model-router request, by routing share
    r = rnd.uniform(0, sum(x[1] for x in ROUTER_POOL)); upto = 0
    for row in ROUTER_POOL:
        upto += row[1]
        if r <= upto:
            return row
    return ROUTER_POOL[-1]

# diurnal shape (UTC hour) + weekday factor — concentrated in EUROPEAN working hours.
# Peak ~11:00 UTC (~13:00 CEST); busy roughly 07:00-15:00 UTC (09:00-17:00 CEST).
def hour_factor(dt):
    h = dt.hour  # UTC
    base = 0.06 + 0.94 * math.exp(-((h - 11) ** 2) / (2 * 3.0 ** 2))
    if dt.weekday() >= 5:   # weekends much quieter
        base *= 0.2
    return base

# ---- build envelopes --------------------------------------------------------
def build_envelopes(devs, ikey):
    now = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0)
    envs = []
    # scale so a median dev makes a sane number of requests across the window
    REQ_PER_WEIGHT_HOUR = float(os.environ.get("REQ_RATE", "12"))
    nbuckets = max(1, WINDOW_MIN // BUCKET_MIN)
    for b in range(nbuckets, 0, -1):
        bucket_start = now - datetime.timedelta(minutes=b * BUCKET_MIN)
        hf = hour_factor(bucket_start)
        for d in devs:
            lam = d["weight"] * hf * REQ_PER_WEIGHT_HOUR * (BUCKET_MIN / 60.0)
            n_req = _poisson(lam)
            tags = {"ai.cloud.role": "apim-foundry", "ai.user.id": d["oid"]}
            # ONE row per request (valueCount==1, like real gateway traffic) so the workbook
            # can bucket requests by context size and compute true cache-hit rates.
            for _ in range(n_req):
                requested = _weighted_choice(d["mix"])
                # model-router forwards to a served underlying model picked per request; record THAT
                # in `model` (mirrors the response's `model` field), and the asked-for name separately.
                if requested == "model-router":
                    model, _, comp_range = _router_pick()
                else:
                    model, comp_range = requested, DIRECT_COMP[requested]
                # jitter within the bucket => distinct timestamps => distinct per-request rows
                ts = bucket_start + datetime.timedelta(seconds=rnd.randint(0, BUCKET_MIN * 60 - 1))
                tstr = ts.strftime("%Y-%m-%dT%H:%M:%S.000Z")
                prompt = int(min(PROMPT_MAX, max(PROMPT_MIN, math.exp(rnd.gauss(*d["ctx_ln"])))))
                clo, chi = comp_range
                completion = rnd.randint(clo, chi)
                # cached prompt tokens: only above the cache threshold; grows with context size
                # and the dev's cache affinity (agentic prefix reuse) — capped at 92%.
                if prompt >= CACHE_MIN_PROMPT:
                    frac = d["cache_aff"] * (0.30 + 0.60 * min(1.0, prompt / 300000.0)) * rnd.uniform(0.7, 1.1)
                    cached = int(min(prompt - 1, max(0, prompt * min(frac, 0.92))))
                else:
                    cached = 0
                props = {"oid": d["oid"], "model": model, "developerName": d["name"],
                         "requestedModel": requested}
                for mname, v in (("Prompt Tokens", prompt), ("Completion Tokens", completion),
                                 ("Total Tokens", prompt + completion), ("Prompt Cached Tokens", cached)):
                    envs.append(_metric_env(ikey, tstr, tags, props, mname, [v]))
    return envs

def _poisson(lam):
    if lam <= 0:
        return 0
    L = math.exp(-lam); k = 0; p = 1.0
    while True:
        k += 1; p *= rnd.random()
        if p <= L:
            return k - 1

def _metric_env(ikey, tstr, tags, props, name, vals):
    n = len(vals); s = float(sum(vals))
    return {
        "name": "Microsoft.ApplicationInsights.Metric",
        "time": tstr,
        "iKey": ikey,
        "tags": tags,
        "data": {"baseType": "MetricData", "baseData": {"ver": 2, "metrics": [{
            "name": name, "kind": "Aggregation", "value": s, "count": n,
            "min": float(min(vals)), "max": float(max(vals))}], "properties": props}},
    }

# ---- ingestion --------------------------------------------------------------
def get_conn():
    # Prefer an explicit connection string (set by the Container Apps Job) so the
    # container needs no Azure CLI / credentials; fall back to `az` locally.
    conn = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
    ikey = None
    if not conn:
        out = subprocess.run(
            ["az", "monitor", "app-insights", "component", "show",
             "--app", APP, "-g", RG, "-o", "json"],
            capture_output=True, text=True)
        if out.returncode != 0:
            sys.exit(f"az failed:\n{out.stderr}")
        p = json.loads(out.stdout)
        conn = p.get("connectionString") or p.get("properties", {}).get("ConnectionString")
        ikey = p.get("instrumentationKey") or p.get("properties", {}).get("InstrumentationKey")
    endpoint = "https://dc.services.visualstudio.com/"
    for part in (conn or "").split(";"):
        if part.startswith("IngestionEndpoint="):
            endpoint = part.split("=", 1)[1]
        if part.startswith("InstrumentationKey="):
            ikey = part.split("=", 1)[1]
    if not endpoint.endswith("/"):
        endpoint += "/"
    return endpoint + "v2/track", ikey

def post_batch(url, batch):
    body = gzip.compress(json.dumps(batch).encode("utf-8"))
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/json", "Content-Encoding": "gzip"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, r.read().decode("utf-8", "ignore")

def main():
    url, ikey = get_conn()
    if not ikey:
        sys.exit("No instrumentation key found.")
    devs = make_devs(N_DEVS)
    envs = build_envelopes(devs, ikey)
    print(f"App Insights : {APP} (rg {RG})")
    print(f"Ingestion    : {url}")
    print(f"Developers   : {len(devs)}   Window: {WINDOW_MIN}m/{BUCKET_MIN}m buckets   Envelopes: {len(envs)}")
    received = accepted = 0
    BATCH = 500
    for i in range(0, len(envs), BATCH):
        batch = envs[i:i + BATCH]
        try:
            status, txt = post_batch(url, batch)
            try:
                j = json.loads(txt)
                received += j.get("itemsReceived", 0); accepted += j.get("itemsAccepted", 0)
            except Exception:
                pass
            print(f"  batch {i//BATCH+1:>3}: HTTP {status}  (+{len(batch)} sent)")
        except urllib.error.HTTPError as e:
            print(f"  batch {i//BATCH+1:>3}: HTTP {e.code}  {e.read()[:300]}")
        except Exception as e:
            print(f"  batch {i//BATCH+1:>3}: ERROR {e}")
    print(f"\nDone. itemsReceived={received} itemsAccepted={accepted}")
    print("Allow ~2-5 min for ingestion, then query customMetrics (see README).")

if __name__ == "__main__":
    main()
