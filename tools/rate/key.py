"""tools/rate/key.py -- the rating cache key. A block is re-rated ONLY when this changes."""
import hashlib, json, os
import config

def _sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()

def rating_key(tree, dep_files, shell_text, row, rating_part, target_ns, harness_paths):
    h = hashlib.sha256()
    for rel in sorted(dep_files):
        p = rel if os.path.isabs(rel) else os.path.join(tree, rel)
        name = "<extra>" + os.path.basename(rel) if os.path.isabs(rel) else rel
        h.update(("%s\0%s\n" % (name, _sha(p))).encode())
    h.update(("shell\0%s\n" % hashlib.sha256(shell_text.encode()).hexdigest()).encode())
    cfg = {"top": row["top"], "generics": row["generics"], "levers": sorted(row["levers"]),
           "clocks": row["clocks"], "part": rating_part, "target_ns": target_ns,
           "vivado": config.VIVADO_VERSION}
    h.update(json.dumps(cfg, sort_keys=True).encode())
    for p in sorted(harness_paths):
        h.update(("%s\0%s\n" % (os.path.basename(p), _sha(p))).encode())
    return h.hexdigest()
