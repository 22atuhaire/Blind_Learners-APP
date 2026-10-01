# App icon

Put the launcher icon here as **`app_icon.png`**, then run:

```
flutter pub get
dart run flutter_launcher_icons
```

That single command rewrites every Android mipmap density, the iOS AppIcon set
and the web icons, replacing Flutter's default blue swirl everywhere at once.

## What the file should be

| Requirement | Value |
|---|---|
| Name | `app_icon.png` (exactly) |
| Format | PNG (not JPEG — the generator expects PNG) |
| Size | square, **1024 × 1024** |
| Content | the **symbol only** — headphones, open book, sound waves |
| Background | the navy panel from the logo |

## Crop the wordmark off

The AudioLearner logo is already drawn as an app icon — rounded navy tile,
symbol centred — which is most of the work. One thing still needs doing:
**crop away the "AudioLearner" text at the bottom.**

Two reasons:

1. **It is unreadable at icon size.** A launcher icon renders at roughly 48dp.
   A wordmark sized for a 1024px canvas becomes an illegible smudge.
2. **Android will cut it off anyway.** This app targets Android 8.0 (API 26)
   and above, where the launcher masks every icon into a circle or squircle
   *of the device manufacturer's choosing*. The text sits in the bottom band —
   exactly the region a circular mask removes.

Crop to the square region containing the headphones, book and waves, keeping
the navy background, and let the symbol fill the frame. The full lockup with
the name still appears on the in-app splash screen, where there is room to
read it.

Do **not** pre-round the corners. Android and iOS apply their own corner
shapes; supplying rounded corners on top produces a visible double-rounded
edge with slivers of background showing.

## Two settings worth knowing

Both live in `pubspec.yaml` under `flutter_launcher_icons`:

- `adaptive_icon_background: "#032A5F"` — the navy behind the adaptive icon,
  sampled from the artwork itself. If the logo's navy ever changes, re-sample
  a corner pixel and update this, or a seam appears at the mask edge.
- `adaptive_icon_foreground_inset: 18` — shrinks the artwork inside the mask's
  safe zone. Raise it if the symbol still touches the edge on a real device.

## Verifying it worked

After running the generator, confirm these no longer show the Flutter logo:

- `android/app/src/main/res/mipmap-*/ic_launcher.png` (5 densities)
- `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` (created)
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/`
- `web/icons/` and `web/favicon.png`

Then rebuild and install:

```
flutter build apk --release --split-per-abi
```

Uninstall any older build from the phone first — Android caches launcher icons
aggressively, and an upgrade install often keeps showing the previous icon.
