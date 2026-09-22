---
name: grokbot-icon
description: Turns an uploaded reference image into a minimal 2D bot-face icon using a locked generation prompt. Use this whenever the user uploads a picture (character art, anime figure, game avatar, photo of a person or mascot, a logo) and wants it turned into a bot / robot face, icon, avatar, profile picture, app icon, or sticker — and also whenever they say things like "把这个图做成机器人头像", "生成机器人图标", "参考这张图做个 bot 脸", "帮我做个极简头像", "make a bot icon from this", "turn this into a minimal robot avatar", or upload a reference image with no instruction at all but clearly want an icon out of it. Trigger even if the user does not say "机器人" or "bot" — any request to convert an uploaded reference into a stylized minimal square icon belongs here.
---

# Grokbot Icon

Convert an uploaded reference image into a minimal 2D bot face, 1:1, on a solid charcoal background.

The output is deliberately **not** a redraw of the reference. Only three things survive from the original: hair color, hair silhouette, and the signature accessory. Everything else — body, face detail, expression, pose, costume, props — is discarded in favor of a large round cream face with two black capsule eyes.

## Workflow

### 1. Get the reference image

If no image was uploaded, ask for one. Do not generate from the prompt alone — the hair color, hair silhouette, and accessory come from the reference, and without it the result is a generic mascot rather than a portrait of that specific character.

If several images are uploaded, ask which one to use.

### 2. Read the reference before generating

Look at the image and name, in your reply to the user, the three features you are carrying over:

- **Hair color** — the dominant color, not every highlight in it
- **Hair silhouette** — the overall shape (long straight, twin tails, bob, spiky, braid…)
- **Signature accessory** — the single most identifying worn item (hairpin, hat, ribbon, horn, headphones, eyepatch…). If nothing stands out, say so and keep none.

Say this out loud to the user *before* generating. It takes one line, and it lets them catch a misread (wrong accessory, wrong hair color) before spending a generation on it.

Then generate.

### 3. Use the locked prompt

Pass the following prompt to the image model **verbatim**. Do not translate it, reword it, shorten it, or merge it with your own description of the reference — every clause is load-bearing, and the negative clauses in particular lose their effect when paraphrased.

```
Reinterpret the accompanying image as a minimal 2D bot face. From the original, keep only the hair color, hair silhouette, and signature accessory. Large round cream-colored face with faint oval blush on the cheeks. Eyes are two identical, parallel, solid black vertical capsules (length:thickness = 3:1). No iris, no sclera, no highlights, no eyelashes, no eyebrows, no mouth, no nose. 1:1 square, solid charcoal background. Extreme close-up composition, head tilted 15 degrees clockwise, peering in from the lower left. Crop the face and hair at the left and bottom edges; both eyes fully visible; empty background space in the upper right. Large masses of hair, pastel flat coloring, minimal shading and detail. No torso, no hands, no weapons, no circular border, no text, no logo, no particles. Prioritize the capsule eyes and mouthless bot face over reproducing the original. Generate one image.
```

Generate exactly one image per request. Do not offer variants unless the user asks for them.

If the image model takes a separate negative prompt field, put this in it:

```
iris, sclera, eye highlights, eyelashes, eyebrows, mouth, nose, torso, hands, weapons, circular border, frame, text, letters, logo, watermark, particles, sparkles, gradient background, shading, 3D render, photorealistic, multiple faces
```

### 4. Check the output before showing it

Look at the generated image against this list. Regenerate if any of these fail — a wrong icon is worse than a slow one:

- Exactly **two** eyes, same size, parallel, solid black, no white inside them
- **No mouth, no nose, no eyebrows** — this is the most common failure; models strongly want to add a mouth
- Background is flat charcoal, edge to edge — not a gradient, not a frame, not a circle
- Both eyes fully inside the frame, face and hair bleeding off the left and bottom edges
- No text, logo, or watermark anywhere
- Square (1:1)

If a check fails twice in a row, tell the user which constraint the model keeps violating rather than burning more generations on it.

### 5. Present the result

Show the image, and state the three carried-over features so the user can confirm the likeness. If they want changes, treat it as a new reference read — re-check the accessory and hair silhouette rather than just re-rolling.

## Notes

- **The Korean original is the source of truth** for the locked prompt. It lives in `references/prompt-ko.md`. If the English and Korean ever disagree, the Korean wins — edit the English to match.
- **Do not add a "keep these features" prefix** to the locked prompt by default. Image models that receive the reference image directly already read it, and an extra prefix tends to make them redraw the original character instead of abstracting it. Add the prefix only if the user reports the model is ignoring the reference entirely.
- **Non-square input is fine.** Portrait, landscape, screenshots — the crop instruction handles it. Only refuse if the reference has no visible head.
- If the reference is already a bot face (someone is re-running the skill on its own output), the result will be nearly identical. That is expected, not a bug.
