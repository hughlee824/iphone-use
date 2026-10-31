# Runner App Icon

The primary Runner icon is [AppIcon.icon](../AppIcon.icon), the approved Icon
Composer document. Keep its JSON and layered SVG assets together. Xcode 27
compiles it into the app icon's layered appearances and compatibility images.
The project resource and `ASSETCATALOG_COMPILER_APPICON_NAME` both use `AppIcon`.
See [Apple's Icon Composer integration guide](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

`AppIcon.appiconset/AppIcon.png` remains the legacy brand-generated catalog
input. Xcode gives the same-named Icon Composer document precedence. The brand
export script only updates that legacy PNG; it must not overwrite the separately
authored `AppIcon.icon`. Shared brand and plugin artwork are unchanged; see the
[brand asset guide](../../assets/brand/README.md).

Build with the shared `IPhoneUseRunner` scheme. UI-test asset catalogs normally
belong to the `.xctest` bundle; the scheme's `install-app-icon.sh` post-action
copies the compiled `Assets.car`, compatibility PNGs and icon metadata to the
generated Runner app and sets its Home Screen name to `iPhone-use`, matching
release packages. It refreshes its signature when signed. This also applies to
CLI source builds and release packaging, which use the same scheme.
