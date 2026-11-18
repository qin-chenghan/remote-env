import os

ENABLED = os.environ.get("MOCK_COUNTERS") == "1"
COUNTS = {}


def bump(name):
    if not ENABLED:
        return
    COUNTS[name] = COUNTS.get(name, 0) + 1
    parts = " ".join(f"{k}={v}" for k, v in sorted(COUNTS.items()))
    print(f"[mock_gpu][g1] {parts}", flush=True)


def wrap(obj, name, label=None):
    fn = getattr(obj, name)
    if not ENABLED:
        # The wrapper itself shows up as a profile frame; only install it
        # when counters are being collected.
        return fn
    tag = label or name

    def wrapper(*a, **k):
        bump(tag)
        return fn(*a, **k)

    setattr(obj, name, wrapper)
    return wrapper
