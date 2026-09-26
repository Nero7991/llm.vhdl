"""tools/rate/tiers.py -- predicted tier clocks = worst measured k x slowest block in the tier.
k from a card build that MET its target is a LOWER BOUND (Vivado stops optimising once met)."""


def tier_min(records, tier):
    rs = [r for r in records if r["tier"] == tier]
    if not rs:
        raise SystemExit("no rated block in tier %s" % tier)
    r = min(rs, key=lambda r: r["achieved_mhz"])
    return r["achieved_mhz"], r["row"]


def k_from_build(card_period_ns, card_wns, tier_min_mhz):
    card_mhz = 1000.0 / (card_period_ns - card_wns)
    return {"k": card_mhz / tier_min_mhz, "lower_bound": card_wns >= 0}


def predict(records, kfile):
    out = {}
    for tier in sorted({r["tier"] for r in records if r["tier"] not in ("calib", "anchor")}):
        ks = kfile.get(tier)
        if not ks:
            raise SystemExit("no k for tier %s on this part: the first card build on a part is the "
                             "calibration of k (spec section 4)" % tier)
        mhz, _ = tier_min(records, tier)
        out[tier] = min(k["k"] for k in ks) * mhz
    return out
