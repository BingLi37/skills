# Darlie Fusion Prompt Template

All reusable prompt text for this skill is in English. Fill every bracketed field from the extraction sheet you wrote for the uploaded source avatar. Never leave a bracket in the prompt you send.

## Image order for `media.generate_image`

1. The uploaded source avatar (the image being fused)
2. `references/assets/darlie-base.jpg` (the Darlie base reference)
3. `references/assets/fusion-example.jpg` (one accepted composition example, reference for layout only, not for identity)

## Main prompt

```text
Create a square 1:1 fused avatar portrait by combining the two reference portraits.

Use the Darlie gentleman portrait as the fixed base composition: a centered head and shoulders bust, head large in frame, shoulders cut off at the bottom edge, solid [BACKGROUND COLOUR, one single saturated solid colour taken from the source character's theme palette, or saturated Darlie green when the source has no clear theme colour] background with no scene and no gradient. The background colour must contrast with the white face and with any white outfit parts, so the white sparkle star stays clearly visible on it.

Keep these Darlie elements exactly: a flat pure white stencil face with bold black silhouette facial features, arched black eyebrows, a stylised black nose shadow, a wide smiling mouth with a second curved smile line under the lower lip, a black bow tie centred at the neck, and a white shirt front below the bow tie. Keep exactly one white four pointed sparkle star on the viewer's right side of the image, at cheek to jaw height, outside the face silhouette.

Remove the Darlie top hat completely. In its place put the source avatar's head feature: [HAIRSTYLE OR HEAD FEATURE, for example spiky short silver grey hair swept up and to the side / long straight hair with blunt bangs / animal ears / a hood / a helmet / antennae], in [SOURCE HEAD COLOURS].

Replace the Darlie tuxedo shoulders with the source avatar's outfit: [OUTFIT, for example a dark high collar tactical jacket / armour with gold trim / a hoodie / a suit with a cape], in [SOURCE OUTFIT COLOURS]. Keep the black bow tie and the white shirt front visible in front of that outfit.

Add the source avatar's signature detail only if it sits on the head or the outfit: [SIGNATURE DETAIL, or the words "none" if there is none].

Render the transplanted hair and outfit in flat vector shapes with tonal facet shading in shades of their own source colours, like cut paper or low polygon facets. Render the face in pure flat black and white with no grey shading. Recognisability comes from the hair, the head feature and the outfit, never from the source face.

Negative constraints: no top hat, no photorealism, no realistic skin, no skin colour on the face, no source character face, no source character eyes, no text, no letters, no brand name, no watermark, no extra people, no extra heads, no extra sparkle stars, no pale washed out background, no gradient background, no background scene, no props held in hands.
```

## Real person mode prompt

Use this prompt instead of the main prompt when the source is a real person's photo. Image order for this mode: 1. the person's photo, 2. `references/assets/realperson-ideal-example.png`, 3. `references/assets/darlie-base.jpg` as a style reference only, never as a face template.

```text
Create a square 1:1 fused avatar portrait of the person in the first reference, rendered in the Darlie gentleman poster style shown in the second reference.

Keep this exact person's identity. Preserve their face shape, eyebrow shape, eyes and gaze direction, nose shape, mouth and smile shape, and both ears, and convert them into a flat pure white face with bold black stencil features and clean black outlines. Let the black shadow shapes follow the person's own face shading, including any cheek shadow. Do not use the Darlie man's nose, mouth or face.

Keep the person's own hairstyle exactly: [HAIRSTYLE, for example a very short black buzz cut following the head shape with a small hairline notch at the centre of the forehead], in [HAIR COLOUR].

Keep the person's own outfit exactly: [OUTFIT, for example a grey collared shirt with the collar up and a black shadow under the chin], in [OUTFIT COLOURS]. Render hair and outfit in smooth clean flat vector shapes with a few flat shade tones. No polygon facets anywhere.

Use a solid [BACKGROUND COLOUR, one saturated bright solid colour that makes the black and white portrait stand out, for example bright yellow] background with no scene and no gradient.

Negative constraints: no bow tie, no white shirt front, no sparkle star, no top hat, no Darlie face template, no different person, no generic face, no photorealism, no realistic skin, no skin colour, no grey shading on the face, no polygon facets, no text, no letters, no watermark, no extra people.
```

Real person validation checklist:

- The person is recognisably themselves, with their own eyebrows, eyes, nose, mouth and face shape
- Face is a flat white stencil face with bold black features and clean outlines, with no skin colour and no grey face shading
- Hairstyle and outfit are the person's own, rendered in smooth flat vector shapes with no polygon facets
- No bow tie, no white shirt front, no sparkle star and no top hat
- Background is one saturated bright solid colour with no scene and no gradient

## Full body source addition

When the uploaded source is a full body or half body standee rather than a head avatar, put this sentence at the start of the main prompt and add "no gun, no fireball, no flames in hands, no full body, no legs" to the negative constraints.

```text
The first reference is a full body character standee: use only its head and its upper body outfit, and ignore its legs, shoes, gun, holster, hands and any skill effect completely.
```

## Retry prompt additions

Use one line per failed checklist item. Add only the lines that match a real mismatch in the generated image.

```text
Fix only this: restore one solid saturated background in the theme colour named in the extraction sheet and remove any pale, washed out or gradient background.
Fix only this: remove the top hat completely and show the source head feature instead.
Fix only this: make the face a flat pure white stencil face with black features and remove all skin colour and realistic facial detail.
Fix only this: centre the black bow tie at the neck and keep the white shirt front visible below it.
Fix only this: keep exactly one white four pointed sparkle star on the viewer's right side at jaw height and remove every other star.
Fix only this: make the source hairstyle and outfit clearer and more recognisable without changing the face.
```

## Validation checklist (read the generated image against every line)

- Square portrait, centered bust, shoulders cut off at the bottom edge
- Background is one solid saturated colour that fits the source theme (Darlie green is the fallback, not a requirement), with no scene and no gradient, and the white sparkle star is clearly visible on it
- Face is a flat pure white stencil face with bold black features and a wide smile
- No top hat anywhere in the image
- Source hairstyle or head feature is present and recognisable
- Source outfit or collar is present and recognisable
- Black bow tie is centred and the white shirt front shows below it
- Exactly one white four pointed sparkle star, on the viewer's right, at cheek to jaw height
- No source face, skin colour, realistic eyes, text, watermark or extra character has leaked in
