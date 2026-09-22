# 잠긴 프롬프트 (원본)

This is the original Korean prompt. It is the source of truth — the English version in `SKILL.md` is a translation, and if the two ever disagree, this file wins.

Keep this file for reference when editing the prompt. Korean is the language this prompt was tuned in, so phrasing changes here are more reliable than changes made directly to the English.

```
함께 제공되는 이미지를 미니멀 2D 봇 얼굴로 재해석하라. 원본에서는 머리색·헤어 실루엣·대표 장식만 유지. 크고 둥근 크림색 얼굴에 옅은 타원형 볼 홍조. 눈은 동일한 크기로 평행하게 놓인 검은 단색 세로 캡슐 두 개(길이:굵기=3:1). 홍채·흰자·반사광·속눈썹·눈썹·입·코 없음. 1:1 정사각형, 차콜 단색 배경. 왼쪽 아래에서 고개를 시계 방향 15° 기울여 들여다보는 초근접 구도. 얼굴과 머리카락은 왼쪽·아래 경계에서 크롭하고 두 눈은 온전히 노출, 오른쪽 위에는 배경 여백. 큰 덩어리의 머리카락, 파스텔 플랫 채색, 최소 음영과 디테일. 몸통·손·무기·원형 테두리·문자·로고·입자 없음. 원본 재현보다 캡슐 눈과 입 없는 봇 얼굴을 우선. 이미지 한 장 생성.
```

## Clause-by-clause

| Korean | English | Why it is there |
|---|---|---|
| 함께 제공되는 이미지를 미니멀 2D 봇 얼굴로 재해석하라 | Reinterpret the accompanying image as a minimal 2D bot face | Frames it as reinterpretation, not redraw |
| 원본에서는 머리색·헤어 실루엣·대표 장식만 유지 | keep only hair color, hair silhouette, signature accessory | The three permitted carry-overs — everything else is dropped |
| 크고 둥근 크림색 얼굴에 옅은 타원형 볼 홍조 | large round cream face, faint oval blush | Cream face is the base; blush is the only warm accent |
| 눈은 동일한 크기로 평행하게 놓인 검은 단색 세로 캡슐 두 개 (길이:굵기=3:1) | two identical parallel solid black vertical capsules, 3:1 | The signature of the style; the ratio keeps it from drifting to dots or ovals |
| 홍채·흰자·반사광·속눈썹·눈썹·입·코 없음 | no iris, sclera, highlights, eyelashes, eyebrows, mouth, nose | The single most-violated constraint — models add a mouth by default |
| 1:1 정사각형, 차콜 단색 배경 | 1:1 square, solid charcoal background | Flat background, no gradient or vignette |
| 왼쪽 아래에서 고개를 시계 방향 15° 기울여 들여다보는 초근접 구도 | extreme close-up, head tilted 15° clockwise, peering in from the lower left | Gives the face its off-axis, leaning-in feel |
| 얼굴과 머리카락은 왼쪽·아래 경계에서 크롭하고 두 눈은 온전히 노출, 오른쪽 위에는 배경 여백 | crop face and hair at left/bottom edges; both eyes fully visible; empty background upper right | Asymmetric crop with negative space — without it the model centers and shrinks the face |
| 큰 덩어리의 머리카락, 파스텔 플랫 채색, 최소 음영과 디테일 | large masses of hair, pastel flat coloring, minimal shading and detail | Flat pastel rendering, hair as shapes not strands |
| 몸통·손·무기·원형 테두리·문자·로고·입자 없음 | no torso, hands, weapons, circular border, text, logo, particles | Prevents the character's body and props leaking in |
| 원본 재현보다 캡슐 눈과 입 없는 봇 얼굴을 우선 | prioritize capsule eyes and mouthless bot face over reproducing the original | Tie-breaker: when the model must choose, the style wins over the likeness |
| 이미지 한 장 생성 | Generate one image | One output, no variants |
