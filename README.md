# NinebotCast (iOS 16.4.1 patched)

Fork of [Corpse-zhao/NinebotCast](https://github.com/Corpse-zhao/NinebotCast) (MIT),
patched so the app launches on iOS 16.4.1.

## What changed vs upstream 0.19.0

- `Sources/MainView.swift`: both `PhotosPicker` uses changed from
  `matching: .images` / `matching: .videos` to `matching: nil`.
  `.images` / `.videos` are `PHPickerFilter` static properties whose Swift
  symbols only exist in the iOS 17+ PhotosUI binary; referencing them makes
  the app die at launch on iOS 16.4.1 with
  `dyld: Symbol not found: _$s8PhotosUI14PHPickerFilterV6imagesACvgZ`
  (the same crash as the original ninebot_pro 1.0.1). Filtering now happens
  after loading: photos are decoded with `UIImage(data:)`, and the video
  flow rejects non-video picks via `supportedContentTypes`.
- The 1024px marketing icon PNG is not in this repo (binary); the
  `AppIcon.appiconset` is empty, so the app builds with a placeholder icon.
  Upload a real icon later if wanted.

Everything else is upstream 0.19.0 unchanged: test image / photo / video /
camera casting to a Ninebot dashboard over UDP 5012/5013, KCP 7-inch preset,
quality presets, background keep-alive.

## Build

GitHub Actions (`.github/workflows/build.yml`, macos-15 + xcodegen) builds an
unsigned IPA; self-sign and install it like the original. No Mac needed.
