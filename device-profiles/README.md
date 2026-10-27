# SmartCrop Frost — supported sensors (device-profile overlay)

Sensor definitions SmartCrop supports that are not (yet) in the upstream
ChirpStack device-profiles repository. `scripts/apply-device-profiles.sh`
merges this folder into the local `lorawan-devices` clone and re-runs the
ChirpStack import, which creates/updates **global** device profiles visible to
every tenant.

Layout mirrors upstream (https://github.com/chirpstack/chirpstack-device-profiles):

    vendors/<vendor>/devices/<model>.toml   device + firmware + which profiles
    vendors/<vendor>/codecs/<model>.js      decodeUplink/encodeDownlink
    vendors/<vendor>/codecs/test_*.json     codec test vectors

Adding a device to an existing vendor: drop the files in, and the apply script
appends the device filename to that vendor's `vendor.toml` devices list.
Region profiles (US915-1_0_3.toml etc.) are reused from the vendor folder.

To contribute upstream later: copy the same files into a fork of the repo and
open a PR — the format is identical.
