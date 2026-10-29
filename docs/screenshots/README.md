# README screenshots

The gallery uses the actual SwiftUI components with synthetic quota values. It is illustrative, not evidence of provider connectivity or signed-binary commissioning. Do not use account data or retouch the interface.

To regenerate the gallery on a Mac with a GUI session, run `scripts/render-screenshots.sh`. It compiles the actual UI with a synthetic model whose provider service is disabled. The menu-bar panel uses the same gauge renderer as the app and shows current and uncertain states.

Review the menu-bar gauges, Essential view in Light appearance, Full view in Dark appearance and Settings in Dark appearance when their visible behaviour changes. Check labels, clipping, contrast and uncertain states; update only the affected captures. After reviewing changed images, run:

```sh
scripts/update-readme-screenshot-manifest.sh
scripts/check-readme-screenshots.sh
```

Normal verification checks required images, README links and image checksums. It does not hash whole Swift files: a comment or nonvisual refactor should not require a new gallery. A release still needs a visual review of the final app and the manual checks in [RELEASING.md](../RELEASING.md).
