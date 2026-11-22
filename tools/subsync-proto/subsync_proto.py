"""Subtitle timing sync — standalone prototype (no app code, no network).

Reference-based: align a target subtitle to a correctly timed reference subtitle.
Signals: 10 ms windows, 1 = a cue is on screen. Score = FFT cross-correlation of (2s-1) signals,
i.e. agreement minus disagreement. Searches a constant offset (±max_offset) and known framerate ratios.
A piecewise pass detects different cuts (scenes added/removed): if parts of the file need clearly different
offsets, the result is reported as "different edit" and NOT offered as a single shift.
"""
import re, sys, json, time, random
import numpy as np

STEP = 0.01  # 10 ms

def parse_time(t):
    t = t.strip().replace(',', '.')
    h, m, s = t.split(':')
    return int(h) * 3600 + int(m) * 60 + float(s)

def parse(text):
    """SRT or ASS → list of (start, end) seconds."""
    cues = []
    if '[Events]' in text or 'Dialogue:' in text:
        fmt = None
        for line in text.splitlines():
            if line.startswith('Format:') and fmt is None and 'Start' in line:
                fmt = [x.strip() for x in line[7:].split(',')]
            if line.startswith('Dialogue:'):
                parts = line[9:].split(',', len(fmt) - 1 if fmt else 9)
                f = fmt or ['Layer', 'Start', 'End']
                cues.append((parse_time(parts[f.index('Start')]), parse_time(parts[f.index('End')])))
    else:
        for m in re.finditer(r'(\d+:\d+:\d+[,.]\d+)\s*-->\s*(\d+:\d+:\d+[,.]\d+)', text):
            cues.append((parse_time(m.group(1)), parse_time(m.group(2))))
    return sorted(cues)

def signal(cues, length):
    s = np.zeros(length, dtype=np.float32)
    for a, b in cues:
        i, j = int(a / STEP), int(b / STEP)
        if j > 0 and i < length:
            s[max(i, 0):min(j, length)] = 1
    return s

def xcorr(ref, tgt):
    """score[k] for shifting tgt by k samples (positive = later)."""
    n = len(ref) + len(tgt)
    size = 1 << (n - 1).bit_length()
    a = 2 * ref - 1; b = 2 * tgt - 1
    r = np.fft.irfft(np.fft.rfft(a, size) * np.conj(np.fft.rfft(b, size)), size)
    # r[k] = sum a[i+k] b[i]; negative k wrap at the end
    return r

def best_offset(ref_cues, tgt_cues, max_offset=60.0):
    end = max(max(b for _, b in ref_cues), max(b for _, b in tgt_cues)) + max_offset + 5
    L = int(end / STEP)
    ref, tgt = signal(ref_cues, L), signal(tgt_cues, L)
    r = xcorr(ref, tgt)
    size = len(r)
    K = int(max_offset / STEP)
    ks = np.concatenate([np.arange(0, K + 1), np.arange(-K, 0)])
    vals = np.array([r[k % size] for k in ks])
    i = int(np.argmax(vals)); k = int(ks[i])
    best = vals[i]
    # confidence: best vs best outside ±1.5 s of it, relative to the speech amount
    mask = np.abs(ks - k) > int(1.5 / STEP)
    second = vals[mask].max() if mask.any() else -np.inf
    speech = float(tgt.sum())
    return k * STEP, float(best), float(second), speech

def overlap_ratio(ref_cues, tgt_cues):
    """Share of target speech time covered by reference speech."""
    L = int((max(b for _, b in ref_cues + tgt_cues) + 5) / STEP)
    a, b = signal(ref_cues, L), signal(tgt_cues, L)
    return float((a * b).sum() / max(b.sum(), 1))

RATIOS = [1.0, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25]

def align(ref_cues, tgt_cues, max_offset=60.0):
    t0 = time.time()
    results = []
    for ratio in RATIOS:
        scaled = [(a * ratio, b * ratio) for a, b in tgt_cues]
        off, best, second, speech = best_offset(ref_cues, scaled, max_offset)
        moved = [(a + off, b + off) for a, b in scaled]
        results.append(dict(ratio=ratio, offset=off, overlap=overlap_ratio(ref_cues, moved),
                            margin=(best - second) / max(speech, 1)))
    results.sort(key=lambda r: r['overlap'], reverse=True)
    top = results[0]
    # piecewise check: split the target in 4 parts by time, align each part alone (±max_offset around global)
    scaled = [(a * top['ratio'], b * top['ratio']) for a, b in tgt_cues]
    n = len(scaled); parts = []
    for q in range(4):
        part = scaled[q * n // 4:(q + 1) * n // 4]
        if len(part) < 5: continue
        off, *_ = best_offset(ref_cues, part, max_offset)
        parts.append(round(off, 2))
    spread = max(parts) - min(parts) if parts else 0
    verdict = ('no_match' if top['overlap'] < 0.6 else
               'different_edit' if spread > 1.0 else
               'confident' if top['overlap'] > 0.8 and top['margin'] > 0.05 else 'uncertain')
    return dict(verdict=verdict, ratio=round(top['ratio'], 6), offset=round(top['offset'], 2),
                overlap=round(top['overlap'], 3), margin=round(top['margin'], 3), part_offsets=parts,
                seconds=round(time.time() - t0, 3))

# ---------- synthetic test files ----------

def make_reference(seed=1, minutes=44):
    rnd = random.Random(seed); t = 5.0; cues = []
    while t < minutes * 60:
        d = rnd.uniform(1.0, 4.5); cues.append((t, t + d)); t += d + rnd.choice([0.2, 0.4, 0.8, 1.5, 3, 6, 12])
    return cues

def srt(cues):
    def ts(x):
        h = int(x // 3600); m = int(x % 3600 // 60); s = x % 60
        return f"{h:02d}:{m:02d}:{int(s):02d},{int(round((s % 1) * 1000)) % 1000:03d}"
    return "\n".join(f"{i+1}\n{ts(a)} --> {ts(b)}\nline {i+1}\n" for i, (a, b) in enumerate(cues))

def cases():
    ref = make_reference()
    yield 'constant +2.50 s', ref, [(a + 2.5, b + 2.5) for a, b in ref], dict(ratio=1.0, offset=-2.5)
    yield 'constant -7.30 s', ref, [(a - 7.3, b - 7.3) for a, b in ref], dict(ratio=1.0, offset=7.3)
    # target made for 25 fps from a 23.976 source: times shorter by 23.976/25, plus 1.2 s
    r = 23.976 / 25
    yield 'speed 25↔23.976 + 1.2 s', ref, [(a * r + 1.2, b * r + 1.2) for a, b in ref], dict(ratio=25 / 23.976, offset=None)
    # different edit: a 40 s scene removed at 15 min in the target's video (so later lines come 40 s earlier there),
    # and a 20 s scene added at 30 min
    def edit(t):
        if t > 1800: return t - 40 + 20
        if t > 900: return t - 40
        return t
    yield 'different edit (-40 s @15m, +20 s @30m)', ref, [(edit(a), edit(b)) for a, b in ref if not 900 < a < 940], dict(edit=True)
    # another translation of the same video: lines split/merged differently, ±0.3 s jitter, 15 % missing, +4 s
    rnd = random.Random(3); other = []
    for a, b in ref:
        if rnd.random() < 0.15: continue
        j = rnd.uniform(-0.3, 0.3)
        if b - a > 3 and rnd.random() < 0.5:
            m = (a + b) / 2; other += [(a + j + 4, m + 4), (m + 0.1 + 4, b + j + 4)]
        else: other.append((a + j + 4, b + j + 4))
    yield 'other translation, jitter, 15% missing, +4 s', ref, other, dict(ratio=1.0, offset=-4.0)
    # unrelated subtitle (another episode)
    yield 'another episode', ref, make_reference(seed=7), dict(unrelated=True)

if __name__ == '__main__':
    out = []
    for name, ref, tgt, expect in cases():
        res = align(ref, tgt)
        out.append(dict(case=name, expect=expect, result=res))
        print(f"{name:42s} → {res['verdict']:15s} ratio {res['ratio']:.4f} offset {res['offset']:+7.2f} s "
              f"overlap {res['overlap']:.2f} margin {res['margin']:.3f} parts {res['part_offsets']} ({res['seconds']} s)")
    json.dump(out, open('results.json', 'w'), ensure_ascii=False, indent=1)
    open('ref.srt', 'w').write(srt(make_reference()))


# ---------- shifting a file while keeping everything else (ASS styles, tags, SRT text) ----------

def fmt_ass(x):
    x = max(0.0, x); h = int(x // 3600); m = int(x % 3600 // 60); s = x % 60
    return f"{h}:{m:02d}:{int(s):02d}.{int(round((s % 1) * 100)) % 100:02d}"

def shift_ass(text, ratio, offset):
    out = []
    for line in text.splitlines(keepends=True):
        if line.startswith('Dialogue:'):
            head, rest = line.split(':', 1)
            parts = rest.split(',', 9)
            for i in (1, 2):
                parts[i] = fmt_ass(parse_time(parts[i]) * ratio + offset)
            line = head + ':' + ','.join(parts)
        out.append(line)
    return ''.join(out)
