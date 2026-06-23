#!/usr/bin/env python3
# ETH II forkchoice driver v2 (LAG + WORK-ARMING).
#
# v1 (deployed) keeps every tenant synced to truth (lag fix) by pushing truth's
# canonical head to each tenant engine API. v2 ADDS validated work-arming so each
# tenant serves FRESH head+1 ethash work that pays its OWN wallet -> correct
# multipool reward routing.
#
# Validated on the isolated lab node (8/8 fresh head+1):
#   per new truth head, per tenant:
#     1) engine_forkchoiceUpdatedV1(head)                      # follow truth (lag)
#     2) engine_forkchoiceUpdatedV1(head, payloadAttributes{   # prime feeRecipient
#          timestamp, prevRandao, suggestedFeeRecipient=wallet })
#     3) wait until tenant head == truth head (<=3s)
#     4) miner_stop ; miner_start(-1)                          # rebuild legacy template
#   -> ethash_getWork then returns head+1 work with coinbase = tenant wallet.
#
# SAFETY:
#  * Only ever feeds truth's REAL canonical head -> cannot fork the chain.
#  * miner_start(-1) does NOT CPU-seal (validated: lab never advanced on its own);
#    it only builds the template that external pool miners pull via getWork.
#  * Arming is gated by ARM=1 in the tenant conf (default OFF) so you can enable
#    one tenant at a time and watch balances. Reversible: ARM=0 + restart, or
#    systemctl disable --now ethii-fc-driver-v2 and re-enable v1.
import json, os, glob, time, urllib.request, hmac, hashlib, base64

TRUTH = "http://127.0.0.1:8545"
TENANTS_DIR = "/opt/ethii-tenants"
FINAL_DEPTH = 64
REDISCOVER_EVERY = 30

def rpc(url, method, params=None, token=None, timeout=10):
    body = json.dumps({"jsonrpc":"2.0","method":method,"params":params or [],"id":1}).encode()
    h = {"Content-Type":"application/json"}
    if token: h["Authorization"] = "Bearer " + token
    return json.load(urllib.request.urlopen(urllib.request.Request(url, data=body, headers=h), timeout=timeout))

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b'=')
def make_jwt(secret_hex):
    s = secret_hex.strip(); secret = bytes.fromhex(s[2:] if s.startswith("0x") else s)
    hdr = b64u(json.dumps({"alg":"HS256","typ":"JWT"},separators=(',',':')).encode())
    pay = b64u(json.dumps({"iat":int(time.time())},separators=(',',':')).encode())
    sig = b64u(hmac.new(secret, hdr+b'.'+pay, hashlib.sha256).digest())
    return (hdr+b'.'+pay+b'.'+sig).decode()

def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

def discover():
    tenants = []
    for f in glob.glob(os.path.join(TENANTS_DIR, "0x*.conf")):
        wallet = os.path.splitext(os.path.basename(f))[0]
        cfg = {}
        try:
            for line in open(f):
                if "=" in line and not line.strip().startswith("#"):
                    k,v = line.strip().split("=",1); cfg[k]=v
        except OSError:
            continue
        authrpc = cfg.get("AUTHRPC_PORT"); internal = cfg.get("INTERNAL_RPC_PORT")
        if not (authrpc and authrpc.isdigit()):
            continue
        jwt = f"/root/ethii-tenant-data-{wallet}/geth/jwtsecret"
        if not os.path.exists(jwt):
            continue
        tenants.append({
            "name": wallet[:10], "wallet": wallet,
            "engine": f"http://127.0.0.1:{authrpc}", "jwt": jwt,
            "internal": f"http://127.0.0.1:{internal}" if internal and internal.isdigit() else None,
            "arm": cfg.get("ARM","0").strip() == "1",
        })
    return tenants

def arm_tenant(t, head_hash, head_ts, head_num):
    """Prime feeRecipient + rebuild legacy template so getWork serves head+1 paying t['wallet']."""
    if not t["internal"]:
        return "no-internal-rpc"
    try:
        tok = make_jwt(open(t["jwt"]).read())
        attrs = {"timestamp": hex(int(head_ts,16)+1),
                 "prevRandao": "0x"+"00"*32,
                 "suggestedFeeRecipient": t["wallet"]}
        st = {"headBlockHash":head_hash,"safeBlockHash":head_hash,"finalizedBlockHash":head_hash}
        rpc(t["engine"], "engine_forkchoiceUpdatedV1", [st, attrs], token=tok, timeout=8)
        # wait for tenant head to apply
        t0 = time.time()
        while time.time()-t0 < 3:
            try:
                ln = int(rpc(t["internal"],"eth_blockNumber")["result"],16)
                if ln >= head_num: break
            except Exception: pass
            time.sleep(0.2)
        rpc(t["internal"], "miner_setEtherbase", [t["wallet"]])
        rpc(t["internal"], "miner_stop")
        rpc(t["internal"], "miner_start", [-1])
        return "armed"
    except Exception as e:
        return f"ARMERR:{e}"

tenants = discover()
log("fc-driver v2 start; tenants=" + str([(t['name'], 'ARM' if t['arm'] else 'lag') for t in tenants]))
last_head = -1
last_disc = time.time()

while True:
    if time.time() - last_disc > REDISCOVER_EVERY:
        new = discover()
        if [(t['name'],t['arm']) for t in new] != [(t['name'],t['arm']) for t in tenants]:
            tenants = new
            log("re-discovered tenants=" + str([(t['name'],'ARM' if t['arm'] else 'lag') for t in tenants]))
        last_disc = time.time()
    try:
        th = int(rpc(TRUTH, "eth_blockNumber")["result"], 16)
    except Exception as e:
        log(f"truth poll err: {e}"); time.sleep(2); continue
    if th != last_head:
        try:
            hb = rpc(TRUTH, "eth_getBlockByNumber", [hex(th), False])["result"]
            head = hb["hash"]; head_ts = hb["timestamp"]
            fin = rpc(TRUTH, "eth_getBlockByNumber", [hex(max(0, th-FINAL_DEPTH)), False])["result"]["hash"]
        except Exception as e:
            log(f"head fetch err: {e}"); time.sleep(1); continue
        st = {"headBlockHash":head, "safeBlockHash":fin, "finalizedBlockHash":fin}
        for t in tenants:
            try:
                tok = make_jwt(open(t["jwt"]).read())
                r = rpc(t["engine"], "engine_forkchoiceUpdatedV1", [st, None], token=tok, timeout=8)
                stt = (r.get("result") or {}).get("payloadStatus", {}).get("status", "?")
            except Exception as e:
                stt = f"ERR:{e}"
            armed = ""
            if t["arm"] and stt in ("VALID","SYNCING"):
                armed = " arm=" + arm_tenant(t, head, head_ts, th)
            if stt not in ("VALID", "SYNCING") or armed.startswith(" arm=ARMERR"):
                log(f"tenant {t['name']} head={th} fcu={stt}{armed}")
        last_head = th
    time.sleep(1)
