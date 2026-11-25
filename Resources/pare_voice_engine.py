"""Pare Voice engine for Pare Guide.

A tiny local web service (127.0.0.1 only) that turns text into speech with Chatterbox,
using the voices saved by the Pare Voice app (~/Documents/Pare Voice/Voices).
Pare Guide starts it when it needs narration and stops it when Pare Guide quits.

Two engines, chosen by Pare Guide (Settings > Voice > Engine):
  standard  PyTorch Chatterbox, at ~/chatterbox (python 3.11 venv)
  mlx       Apple's MLX version (mlx-audio), at ~/pare-voice-mlx; usually faster on Apple Silicon
Nothing leaves the Mac.
"""
import gc
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VOICES = os.path.join(os.path.expanduser("~"), "Documents", "Pare Voice", "Voices")


class Engine:
    """Keeps one model in memory; switching between Fast and Expressive swaps it."""

    def __init__(self):
        self.model = None
        self.kind = None
        self.device = None
        self.cond_key = None
        self.lock = threading.Lock()
        self.patched = False

    def load(self, kind):
        if self.model is not None and self.kind == kind:
            return self.model
        import torch
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        if not self.patched:  # weights were saved on CUDA; map them for this Mac
            _load = torch.load
            torch.load = lambda *a, **k: _load(*a, **{**k, "map_location": torch.device("cpu")})
            self.patched = True
        if self.model is not None:
            self.model = None
            gc.collect()
            if self.device == "mps":
                torch.mps.empty_cache()
        if kind == "turbo":
            from chatterbox.tts_turbo import ChatterboxTurboTTS
            self.model = ChatterboxTurboTTS.from_pretrained(device=self.device)
        else:
            from chatterbox.tts import ChatterboxTTS
            self.model = ChatterboxTTS.from_pretrained(device=self.device)
        self.kind = kind
        self.cond_key = None
        return self.model

    def say(self, text, ref, kind, exaggeration, cfg, out_path):
        import torch
        import torchaudio as ta
        with self.lock:
            m = self.load(kind)
            key = (kind, ref, os.path.getmtime(ref))
            if key != self.cond_key:  # analyse the voice sample once, then reuse it
                m.prepare_conditionals(ref, exaggeration=0.0 if kind == "turbo" else float(exaggeration))
                self.cond_key = key
            if kind == "turbo":
                wav = m.generate(text)
            else:
                wav = m.generate(text, exaggeration=float(exaggeration), cfg_weight=float(cfg))
            ta.save(out_path, wav, m.sr)
            return wav.shape[-1] / m.sr


class MLXEngine:
    """The same voices through mlx-audio, Apple's MLX framework for M-series chips."""

    REPOS = {
        "turbo": ["mlx-community/chatterbox-turbo-fp16", "mlx-community/chatterbox-turbo-8bit",
                  "mlx-community/chatterbox-turbo-4bit"],
        "standard": ["mlx-community/chatterbox-fp16", "mlx-community/chatterbox-8bit"],
    }

    def __init__(self):
        self.model = None
        self.kind = None
        self.cond_key = None
        self.conds = None
        self.lock = threading.Lock()

    def load(self, kind):
        if self.model is not None and self.kind == kind:
            return self.model
        from mlx_audio.tts.utils import load_model
        self.model = None
        gc.collect()
        last = None
        for repo in self.REPOS.get(kind, self.REPOS["turbo"]):
            try:
                self.model = load_model(repo)
                print("loaded", repo, flush=True)
                break
            except Exception as e:  # try the next size
                last = e
                print("couldn't load", repo, e, flush=True)
        if self.model is None:
            raise RuntimeError(f"Couldn't load the fast {kind} voice model: {last}")
        self.kind = kind
        self.cond_key = None
        self.conds = None
        return self.model

    def say(self, text, ref, kind, exaggeration, cfg, out_path):
        import numpy as np
        from scipy.io import wavfile
        with self.lock:
            m = self.load(kind)
            ex = float(exaggeration)
            key = (kind, ref, os.path.getmtime(ref), None if kind == "turbo" else ex)
            if key != self.cond_key:  # analyse the voice sample once, then reuse it
                if kind == "turbo":
                    m.prepare_conditionals(ref)
                else:
                    self.conds = m.prepare_conditionals(ref, 24000, ex)
                self.cond_key = key
            if kind == "turbo":
                results = m.generate(text)
            else:
                results = m.generate(text, conds=self.conds, exaggeration=ex, cfg_weight=float(cfg), verbose=False)
            parts, sr = [], None
            for r in results:
                parts.append(np.array(r.audio, dtype=np.float32).reshape(-1))
                sr = r.sample_rate
            sr = int(sr or getattr(m, "sample_rate", 24000))
            wav = np.concatenate(parts) if parts else np.zeros(1, dtype=np.float32)
            wavfile.write(out_path, sr, wav)
            return len(wav) / float(sr)


ENGINE_NAME = sys.argv[2] if len(sys.argv) > 2 else "standard"
ENGINE = MLXEngine() if ENGINE_NAME == "mlx" else Engine()


# ---------------------------------------------------------------- adding voices

def best_speech_window(a, sr, length=14.0):
    """The stretch with the most continuous speech: few long pauses, no clipping."""
    import numpy as np
    if len(a) / sr <= length + 2:
        return a
    f = int(0.05 * sr)
    n = len(a) // f
    fr = a[: n * f].reshape(n, f)
    rms = 20 * np.log10(np.sqrt((fr ** 2).mean(1)) + 1e-9)
    pk = np.abs(fr).max(1)
    thr = max(np.percentile(rms, 60) - 12, -45)
    speech = rms > thr
    W = int(length / 0.05)
    best, best_s = -1e9, 0
    for s in range(0, n - W, 10):
        w = speech[s: s + W]
        if pk[s: s + W].max() > 0.97:
            continue
        idx = np.where(np.concatenate([[1], w.astype(int), [1]]) == 1)[0]
        gap = (np.diff(idx) - 1).max() * 0.05
        score = w.mean() - 0.15 * max(0, gap - 0.6)
        if score > best:
            best, best_s = score, s
    s, e = best_s, best_s + W
    for k in range(20):  # start and end on quiet moments
        if s - k > 0 and rms[s - k] < thr - 6:
            s -= k
            break
    for k in range(20):
        if e + k < n and rms[e + k] < thr - 6:
            e += k
            break
    return a[s * f: e * f]


TOOLS = os.path.expanduser("~/pare-voice-tools")   # separate environment so it can't upset Chatterbox
SEPARATOR = os.path.join(TOOLS, "bin", "audio-separator")


def remove_music(path, workdir):
    """Keeps only the voice, using the music remover installed by Pare Guide's setup."""
    import subprocess
    if not os.path.exists(SEPARATOR):
        raise RuntimeError("The music remover isn't installed. Click Repair or Update in Settings › Voice.")
    env = dict(os.environ, PATH=os.path.join(TOOLS, "bin") + ":/usr/bin:/bin")
    r = subprocess.run([SEPARATOR, path, "--model_filename", "Kim_Vocal_2.onnx", "--output_format", "WAV",
                        "--single_stem", "Vocals", "--model_file_dir", os.path.join(TOOLS, "models"),
                        "--output_dir", workdir], capture_output=True, text=True, env=env, timeout=1800)
    outs = [f for f in os.listdir(workdir) if f.lower().endswith(".wav") and "vocals" in f.lower()]
    if r.returncode != 0 or not outs:
        raise RuntimeError("Removing the music didn't work: " + (r.stderr or r.stdout)[-300:])
    return os.path.join(workdir, outs[0])


def add_voice(src, name, clean):
    import numpy as np
    import librosa
    import soundfile as sf
    import tempfile
    os.makedirs(VOICES, exist_ok=True)
    work = tempfile.mkdtemp(prefix="parevoice-")
    path = src
    if clean:
        path = remove_music(src, work)
    a, sr = librosa.load(path, sr=24000, mono=True)
    if len(a) / sr < 7:
        raise ValueError("That recording is under 7 seconds. Use 10-20 seconds of clear speech.")
    clip = best_speech_window(a, sr)
    clip = clip - clip.mean()
    clip = clip * (10 ** (-18 / 20) / (np.sqrt((clip ** 2).mean()) + 1e-9))
    pk = np.abs(clip).max()
    if pk > 0.95:
        clip = clip * (0.95 / pk)
    fade = int(0.03 * sr)
    clip[:fade] *= np.linspace(0, 1, fade)
    clip[-fade:] *= np.linspace(1, 0, fade)
    out = os.path.join(VOICES, name + ".wav")
    sf.write(out, clip, sr, subtype="PCM_16")
    return len(clip) / sr


def list_voices():
    try:
        return sorted(os.path.splitext(f)[0] for f in os.listdir(VOICES)
                      if f.lower().endswith(".wav") and not f.startswith("."))
    except FileNotFoundError:
        return []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"ok": True, "loaded": ENGINE.kind, "engine": ENGINE_NAME})
        elif self.path == "/capabilities":
            self.reply(200, {"removeMusic": os.path.exists(SEPARATOR)})
        elif self.path == "/voices":
            self.reply(200, {"voices": list_voices()})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/warm":
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
            kind = req.get("mode", "turbo")

            def warm():
                try:
                    with ENGINE.lock:
                        ENGINE.load(kind)
                except Exception as e:
                    print("warm-up failed:", e, flush=True)
            threading.Thread(target=warm, daemon=True).start()
            return self.reply(200, {"ok": True})
        if self.path == "/addvoice":
            try:
                n = int(self.headers.get("Content-Length", "0"))
                req = json.loads(self.rfile.read(n) or b"{}")
                secs = add_voice(req["src"], req["name"], bool(req.get("clean")))
                return self.reply(200, {"ok": True, "seconds": secs})
            except Exception as e:
                return self.reply(500, {"error": f"{type(e).__name__}: {e}"})
        if self.path != "/say":
            return self.reply(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("text") or "").strip()
            voice = req.get("voice") or ""
            ref = os.path.join(VOICES, voice + ".wav")
            if not text:
                return self.reply(400, {"error": "No text to read."})
            if not os.path.exists(ref):
                return self.reply(400, {"error": f"The voice '{voice}' isn't in Pare Voice."})
            secs = ENGINE.say(text, ref, req.get("mode", "turbo"), req.get("exaggeration", 0.45),
                              req.get("cfg", 0.5), req["out"])
            self.reply(200, {"ok": True, "seconds": secs})
        except Exception as e:  # report the problem to Pare Guide instead of crashing
            self.reply(500, {"error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7866
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
