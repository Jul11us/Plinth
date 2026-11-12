"""Prototype: repaint the pasted hair of a Plinth try-on with a local inpainting model.

Reads what `HairTryOnTests.testRepaintInputs` wrote (<key>-photo/draft/mask/hair.png, <key>-prompt.txt) and writes
<key>-<tag>.png (the result on the 960x1200 canvas). Only the masked area changes; the rest is the photo's own pixels.

Two passes:
  1. clear: where the old hair was painted out and the new style doesn't cover it, redraw what is behind it
     (background, neck, shoulders) from the surroundings.
  2. hair: redraw the new hair over the pasted draft, which fixes its outline and flow.

Run (needs torch, diffusers, transformers, accelerate, pillow; the model downloads on first use, about 2 GB):
  REPAINT_OUT=in REPAINT_PHOTOS=photos REPAINT_STYLES=m4,f6 swift test -c release --filter HairTryOnTests/testRepaintInputs
  python scripts/repaint-proto.py --inp in --out out --keys <photo>-m4,<photo>-f6

REPAINT_SHADE=<id> exports a dyed colour (files get a -<id> suffix).

The app's version (Sources/FitHair/Analysis/HairRepaint.swift) has since moved on from this script: it always runs
the clear pass when anything is left bare, clears again when hair is still found there, and its mask also takes in
loose strands found by colour. Its hair pass runs at strength 0.6 (7 of 12 steps) over the hair and the skin next to
it, so the hair is grown on the sitter's head rather than copied from the bust; at 0.5 it looked like a wig.
Faded sides are thinned in the draft so the scalp shows, and the result is sharpened (not only softened) to the
photo's own sharpness.

Found by trying it on real photos:
  - Strength 0.5 keeps the cut recognisable; above about 0.65 the model drifts to a generic cut.
  - The clear pass starts from the smoothed-over photo at 0.88, so clothes keep their colours; at 1.0 it invents new ones.
  - The model's hair is sharper than most photos at this size, so the result is softened to match the photo.
  - 512 px is the size to use: 768 did not finish in ten minutes on a 16 GB Mac.

Speed, on an M5 with 16 GB (PyTorch on the GPU; about 5 s a picture, 14 s when the clear pass runs):
  - Attention slicing halves a step (1.10 s to 0.59 s) with the same picture.
  - 12 steps at strength 0.5 is 6 real steps, and looks the same as 20.
  - Guidance only for the first half of the hair steps (a step without it is 0.34 s). The clear pass keeps it throughout:
    its "no hair" is a negative prompt, and without guidance long hair grows back.
  - The clear pass only runs when more than 12% of the canvas is left bare (long hair to a short cut). Below that one
    pass over the whole mask looks the same. A smaller clear pass (384 px) leaves a pale rim around the hair.
"""
import argparse, os, time
import numpy as np
import torch
from PIL import Image, ImageFilter, ImageChops
from diffusers import AutoPipelineForInpainting, DPMSolverMultistepScheduler

MODEL = "Lykon/dreamshaper-8-inpainting"
NEG_HAIR = ("wig, plastic, sculpture, clay, painting, cartoon, 3d render, hat, headband, hair clip, hairpin, beads, "
            "blurry, smudged, extra face, extra ear, deformed, text")
NEG_CLEAR = "hair, long hair, ponytail, braid, strands, wig, fur, hat, head, face, extra person, hand, earrings, text, blurry"


def colour_word(draft, hair):
    """A plain word for the hair colour of the draft, for the prompt."""
    px = np.asarray(draft, np.float32)[np.asarray(hair) > 200] / 255
    if len(px) < 500:
        return "dark"
    r, g, b = np.median(px, axis=0)
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    if lum < 0.16:
        return "black"
    if max(r, g, b) - min(r, g, b) < 0.06:
        return "dark grey" if lum < 0.4 else ("grey" if lum < 0.65 else "silver white")
    if lum < 0.3:
        return "dark brown"
    if lum < 0.5:
        return "auburn" if r > b * 1.9 else "brown"
    return "blonde"


def crop_box(mask, pad):
    """The part of the canvas the model sees: the masked area with context around it, squared up where there is room."""
    w, h = mask.size
    x0, y0, x1, y1 = mask.getbbox()
    m = int(max(x1 - x0, y1 - y0) * pad / 2)
    x0, y0, x1, y1 = max(0, x0 - m), max(0, y0 - m), min(w, x1 + m), min(h, y1 + m)
    bw, bh = x1 - x0, y1 - y0
    if bw < bh:
        bw2 = min(bh, w)
        x0 = max(0, min(w - bw2, x0 - (bw2 - bw) // 2)); x1 = x0 + bw2
    else:
        bh2 = min(bw, h)
        y0 = max(0, min(h - bh2, y0 - (bh2 - bh) // 2)); y1 = y0 + bh2
    return (x0, y0, x1, y1)


def model_size(box, side):
    """Width and height for the model with about side x side pixels and the shape of `box`, in multiples of 8."""
    bw, bh = box[2] - box[0], box[3] - box[1]
    k = (side * side / (bw * bh)) ** 0.5
    return max(64, round(bw * k / 8) * 8), max(64, round(bh * k / 8) * 8)


def fineness(image, region):
    """How much of the detail in `region` is fine rather than coarse: high for a sharp picture, low for a soft one,
    whatever its contrast."""
    lum = image.convert("L")
    f = lambda r: np.asarray(lum.filter(ImageFilter.GaussianBlur(r)), np.float32)
    g0, g1, g3 = np.asarray(lum, np.float32), f(1.2), f(3.6)
    sel = np.asarray(region) > 127
    if sel.sum() < 500:
        return None
    return float(np.abs(g0 - g1)[sel].mean() / (np.abs(g1 - g3)[sel].mean() + 1e-3))


def soften_to_match(result, photo, area, box):
    """Blurs the redrawn area until it is no sharper than the photo around it, so new hair doesn't sit on a soft photo
    like a sticker."""
    window = Image.new("L", photo.size, 0)
    window.paste(255, box)
    want = fineness(photo, window)
    have = fineness(result, area)
    if want is None or have is None or have <= want * 1.1:
        return result, 0.0
    lo, hi = 0.0, 4.0
    for _ in range(6):
        mid = (lo + hi) / 2
        if fineness(result.filter(ImageFilter.GaussianBlur(mid)), area) > want * 1.1:
            lo = mid
        else:
            hi = mid
    soft = result.filter(ImageFilter.GaussianBlur(hi))
    return Image.composite(soft, result, area.filter(ImageFilter.GaussianBlur(4))), hi


def grow(mask, px):
    return mask.filter(ImageFilter.MaxFilter(px * 2 + 1)) if px > 0 else mask


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--keys", required=True, help="comma separated, e.g. a1-m4,g02-f1")
    ap.add_argument("--strength", type=float, default=0.5)
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--steps", type=int, default=12)
    ap.add_argument("--cfg", type=float, default=6.5)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--pad", type=float, default=0.2)
    ap.add_argument("--tag", default="repaint")
    ap.add_argument("--clear-over", type=float, default=0.12, help="run the clear pass when more of the canvas than this is left bare")
    ap.add_argument("--clear-strength", type=float, default=0.88)
    ap.add_argument("--clear-size", type=int, default=512)
    ap.add_argument("--clear-steps", type=int, default=12)
    ap.add_argument("--guided", type=float, default=0.5, help="part of the hair steps that use guidance")
    ap.add_argument("--clear-guided", type=float, default=1.0, help="the same for the clear pass, whose 'no hair' needs it")
    ap.add_argument("--one-pass", action="store_true")
    ap.add_argument("--no-soften", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    pipe = AutoPipelineForInpainting.from_pretrained(MODEL, variant="fp16", torch_dtype=torch.float16, safety_checker=None,
                                                     requires_safety_checker=False)
    pipe.scheduler = DPMSolverMultistepScheduler.from_config(pipe.scheduler.config, use_karras_sigmas=True,
                                                             algorithm_type="dpmsolver++")
    pipe = pipe.to("mps")
    pipe.set_progress_bar_config(disable=True)
    pipe.enable_attention_slicing()     # same picture, about half the time per step on a 16 GB Mac

    def guided_for(part):
        """Guidance doubles the work of a step and matters most early on: drop it after `part` of the steps."""
        def after_step(pipe, i, t, kw):
            if part < 1 and pipe.do_classifier_free_guidance and i + 1 >= max(1, round(pipe.num_timesteps * part)):
                pipe._guidance_scale = 1.0
                for name in ("prompt_embeds", "mask", "masked_image_latents"):
                    kw[name] = kw[name].chunk(2)[-1]
            return kw
        return after_step

    def redraw(canvas, init, mask, prompt, negative, strength, size, steps, guided):
        """Redraws `mask` of `canvas`, starting from `init`; returns the canvas with only that area changed."""
        box = crop_box(mask, a.pad)
        w, h = model_size(box, size)
        crop = lambda im, mode: im.crop(box).resize((w, h), mode)
        out = pipe(prompt=prompt, negative_prompt=negative, image=crop(init, Image.LANCZOS), mask_image=crop(mask, Image.BILINEAR),
                   strength=strength, guidance_scale=a.cfg, num_inference_steps=steps, width=w, height=h,
                   generator=torch.Generator("cpu").manual_seed(a.seed), callback_on_step_end=guided_for(guided),
                   callback_on_step_end_tensor_inputs=["prompt_embeds", "mask", "masked_image_latents"]).images[0]
        patch = Image.new("RGB", canvas.size)
        patch.paste(out.resize((box[2] - box[0], box[3] - box[1]), Image.LANCZOS), box[:2])
        return Image.composite(patch, canvas, mask.filter(ImageFilter.GaussianBlur(4))), box

    for key in a.keys.split(","):
        base = os.path.join(a.inp, key)
        if not os.path.exists(base + "-draft.png"):
            print("missing", key)
            continue
        photo = Image.open(base + "-photo.png").convert("RGB")
        draft = Image.open(base + "-draft.png").convert("RGB")
        mask = Image.open(base + "-mask.png").convert("L").point(lambda v: 255 if v > 127 else 0)
        hair = Image.open(base + "-hair.png").convert("L")
        style, _, named = open(base + "-prompt.txt").read().strip().partition("\n")
        # CLIP reads 77 tokens: the style first, then only what matters most.
        prompt = f"photo, {named.strip() or colour_word(draft, hair)} hair, {style}, real hair strands, natural hairline"

        t = time.time()
        solid = hair.point(lambda v: 255 if v > 127 else 0)
        hair_area = ImageChops.multiply(grow(hair.point(lambda v: 255 if v > 13 else 0), 8), mask)
        clear = ImageChops.subtract(mask, solid)
        passes = 1
        result = photo
        uncovered = np.count_nonzero(np.asarray(ImageChops.subtract(mask, hair_area))) / (mask.width * mask.height)
        two = not a.one_pass and uncovered > a.clear_over
        if two:
            result, _ = redraw(photo, draft, clear, "photo, plain background, bare neck, ears, shoulders, clothes", NEG_CLEAR, a.clear_strength,
                               a.clear_size, a.clear_steps, a.clear_guided)
            passes = 2
        t_clear = time.time() - t
        target = hair_area if two else mask
        init = Image.composite(draft, result, target)
        result, box = redraw(result, init, target, prompt, NEG_HAIR, a.strength, a.size, a.steps, a.guided)
        t_hair = time.time() - t - t_clear
        blur = 0.0
        if not a.no_soften:
            result, blur = soften_to_match(result, photo, target, box)
        result.save(f"{os.path.join(a.out, key)}-{a.tag}.png")
        total = time.time() - t
        print(f"{key}: {total:.1f}s = clear {t_clear:.1f} + hair {t_hair:.1f} + soften {total - t_clear - t_hair:.1f}, "
              f"{passes} pass(es), softened {blur:.1f}px")


if __name__ == "__main__":
    main()
