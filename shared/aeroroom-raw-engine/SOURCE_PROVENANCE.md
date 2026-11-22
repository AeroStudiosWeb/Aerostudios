# AeroRoom engine source provenance

These are the `lightcraft-raw`, `lightcraft-color`, `lightcraft-geom`,
`lightcraft-raster`, and `lightcraft-meta` library crates taken from the
user's `AeroRoomStudio_Rust_Fork_v0.1.zip` archive (itself a fork of LightCraft).
Only workspace manifests were trimmed to remove unrelated apps and dev-only
crates. Decoder, colour, and demosaicing source files are unchanged.

Original engine licence: MIT OR Apache-2.0. See `LICENSE-MIT`,
`LICENSE-APACHE`, and `NOTICE`.

The decoder uses external Craft libraries pinned in its upstream workspace
manifest. They are fetched by Cargo during the first build.

Do not treat the list of supported file extensions as a promise that all
camera bodies / compression variants are supported. Test real camera samples.
