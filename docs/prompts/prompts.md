# Plinth 提示词

所有图片统一风格：哑光白石膏胸像、暖灰背景、左上方柔光、4:5 竖图（1024×1280）。
英文提示词效果更稳定；把 `{…}` 换成下面列表里的对应内容。

---

## 1. 七种脸型白模（同一个人，只变脸型）

想让首页的变形动画更丝滑，七张必须是**同一个人、同一个发型、同一个角度**。
先生成一张满意的鹅蛋脸，把它当参考图（支持参考图的工具里勾选"保持人物一致"），再生成另外六张。

```
Studio photograph of a matte white plaster bust sculpture of a young East Asian woman, modern classical sculpture style, eyes open with a calm gaze, hair sculpted smoothly pulled back into a sleek low bun so the full face outline, forehead and jawline are clearly visible. Same person, same hairstyle, same pose and same lighting as the reference image; change ONLY the face shape. Her face shape is a textbook {FACE SHAPE}. Head, neck and the top of the shoulders, cut flat like a museum bust. Front view turned about 10 degrees. Soft diffused studio key light from upper left, gentle shadows. Plain seamless light warm-gray background (#DCDAD7), no props, no text. Minimal, high-end fashion editorial, centered, space above the head.
```

| 脸型 | {FACE SHAPE} |
|---|---|
| 鹅蛋 | OVAL face: length about 1.5 times the width, forehead slightly wider than the jaw, softly rounded jawline, gently tapered chin |
| 圆 | ROUND face: length and width almost equal, full cheeks are the widest part, soft rounded jaw with no angles, short rounded chin |
| 方 | SQUARE face: forehead, cheekbones and jaw about the same width, strong straight angular jaw with sharp corners, broad flat chin |
| 心形 | HEART face: wide forehead is the widest part, high cheekbones, narrowing to a slim jaw and a small pointed chin |
| 长 | OBLONG face: clearly much longer than wide, forehead, cheekbones and jaw similar narrow widths, long straight cheeks, long chin |
| 菱形 | DIAMOND face: high prominent cheekbones are clearly the widest part, narrow forehead, narrow tapered jaw, defined pointed chin |
| 三角 | TRIANGLE face: wide strong jaw is the widest part, narrower cheekbones, narrow forehead, broad lower face |

男生版：把 `a young East Asian woman … pulled back into a sleek low bun` 换成 `a young East Asian man … short neatly cropped sculpted hair`。

---

## 2. 发型白模（正面 / 侧面 / 背面）

```
Studio photograph of a matte white plaster bust sculpture of a {PERSON} with an oval face, modern classical sculpture style, eyes open with a calm gaze. The hair is sculpted in the same white plaster with fine carved strands: {HAIRSTYLE}. {VIEW}. Head, neck and the top of the shoulders, cut flat like a museum bust. Soft diffused studio key light from upper left, gentle shadows. Plain seamless light warm-gray background (#DCDAD7), no props, no text. Minimal, high-end fashion editorial, centered, space above the head.
```

{PERSON}：`beautiful young East Asian woman` 或 `handsome young East Asian man`

{VIEW}：
- 正面：`Front view turned about 10 degrees`
- 侧面：`Exact side profile view facing left, showing the length and layers from the side`
- 背面：`View from directly behind, showing the back of the hair and the nape`

每款发型的 {HAIRSTYLE} 写在 `Sources/FitHair/Resources/hairstyles.json` 的 `prompt` 字段里。
跑 `python3 scripts/hairstyle-prompts.py` 会把还没有图的发型的完整提示词打印出来，生成后存成 `Sources/FitHair/Resources/hair-<id>.jpg`（4:5，现有的是 640×800）。

---

## 3. 试戴（给图片编辑模型：上传用户照片 + 这段文字）

```
Edit this photo. Change ONLY the hairstyle to: {HAIRSTYLE}. Keep everything else exactly the same: the same face, facial features, skin tone, expression, head angle, clothing, background and lighting. Keep the person's natural hair color and realistic hair texture and density. Photorealistic, no retouching of the face.
```

{HAIRSTYLE} 用第 2 节表格里的描述。不要把白模图当参考图上传，否则头发会变成白色。

---

## 4. App 图标（三个方向 · 详细版）

扁平线条版做出来容易显得廉价，所以三个方向都改成 macOS 风格的**立体实物图标**：一个有材质、有光影的小物件放在圆角方块上，和 App 里的石膏白模是同一种质感。

**通用做法（很重要）**
- 尺寸 1024×1024，正方形。
- 最好**只生成物体本身**（纯色背景），再放进 Figma 里自己做的圆角方块（macOS 圆角约 22.5%、四周留约 10% 边距）。AI 直接画的圆角方块经常歪、边缘脏。
- Midjourney 可在末尾加 `--ar 1:1 --style raw`；其他工具把 Negative 那段放进反向提示词。
- 生成后缩到 32 px 看一眼：主体轮廓还认得出才算合格。

---

### A · 石膏头像 + 橙色量尺（推荐）

和首页的石膏白模、橙色测量线是同一套语言，最像这个 App。

```
A premium macOS app icon, 1024x1024. Subject: a small, smooth, abstract white plaster head sculpture shown in a three-quarter view facing left, carved like a modern museum bust: idealized and calm, closed simple eyelids, only a gentle suggestion of the nose, lips and brow, no hair, no ears detail, ending in a clean flat cut at the neck. Material: matte, slightly porous chalk-white plaster (#EDEBE7) with very fine surface grain and soft subsurface warmth. Detail: one thin, glossy bright orange (#FF5A1F) measuring tape wraps horizontally around the head at cheekbone height, with tiny black tick marks printed on it; the tape's loose end curls gently outward to the right, like a tailor measuring a face. Composition: the head is centered and occupies about 62% of the tile height, with generous even padding; the tape is the only color accent. Tile: a macOS Big Sur–style squircle with a deep matte charcoal background (#141414) and a very subtle top-to-bottom tonal falloff, thin soft inner highlight along the top edge. Lighting: soft studio key light from the upper left, gentle fill from the right, a soft contact shadow under the neck, delicate ambient occlusion in the eye sockets and under the chin. Style: high-end Apple product icon, clean, calm, sculptural, photoreal 3D render, ultra sharp, minimal.
Negative: text, letters, logos, realistic skin, colored skin, hair strands, glossy plastic, cartoon, emoji, clutter, multiple objects, heavy gradients, neon glow, frame, border, watermark, low resolution, noisy, warped tile.
```

---

### B · 剪刀（高级版）

保留剪刀，但做成一把有质感的专业理发剪，而不是简笔画。

```
A premium macOS app icon, 1024x1024. Subject: a single pair of professional Japanese hair-cutting shears, slightly open in a narrow V, placed diagonally from lower left to upper right. Material: blades in matte black ceramic-coated steel (#111111) with a thin brushed-silver polished cutting edge catching the light; ergonomic offset finger rings in the same matte black; a small round pivot screw in glossy bright orange anodized metal (#FF5A1F) as the only color accent, plus a small orange finger-rest tang. Composition: the shears are centered, occupy about 70% of the tile diagonal, with generous padding and a clean silhouette; the open blades form an elegant narrow angle. Tile: a macOS Big Sur–style squircle in soft warm light gray (#DCDAD7) with a matte paper-like finish and a very subtle radial falloff toward the edges. Lighting: soft studio softbox from the upper left creating one long crisp specular line along each blade edge, a soft realistic drop shadow cast down-right onto the tile, subtle reflected light on the rings. Style: high-end Apple product icon, precise industrial design, photoreal 3D render, ultra sharp, minimal, luxury barber tool.
Negative: text, letters, logo, hair, comb, multiple tools, rust, scratches, chrome mirror finish, cartoon, flat clip-art, thick outlines, cluttered background, heavy gradients, neon, frame, border, watermark, low resolution, warped tile.
```

---

### C · 卡尺量脸

一把橙色游标卡尺夹住一个石膏脸的两颊——「先量再剪」最直接的画面，独特度最高。

```
A premium macOS app icon, 1024x1024. Subject: a smooth abstract white plaster face mask seen from the front — an elegant oval face with only a soft suggestion of brow, nose and lips, no eyes detail, no hair — being measured by a slim vernier caliper. The caliper is made of glossy bright orange anodized aluminum (#FF5A1F) with fine engraved black tick marks; its two jaws gently touch the left and right cheekbones of the face, the caliper beam runs horizontally across the face just below the eyes. Material: the face is matte chalk-white plaster (#EDEBE7) with fine grain and soft shading; the caliper is crisp, precise and slightly reflective. Composition: the face is centered and fills about 60% of the tile height; the caliper extends slightly beyond the face on both sides, creating a strong horizontal line; generous even padding. Tile: a macOS Big Sur–style squircle in deep matte black (#0E0E0E) with a faint warm top highlight. Lighting: soft key light from the upper left, gentle rim light on the right edge of the face, a subtle shadow of the caliper falling on the plaster. Style: high-end Apple product icon, precise, calm, sculptural, photoreal 3D render, ultra sharp, minimal.
Negative: text, numbers, letters, logo, realistic human skin, eyes with pupils, hair, ruler, measuring tape, multiple objects, cartoon, flat clip-art, neon glow, heavy gradients, frame, border, watermark, low resolution, warped tile.
```
