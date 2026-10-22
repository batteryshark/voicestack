# Optional hold music

The call UI supports a pickup greeting and optional looping hold music while the
bound conversation has authoritative active execution. Reply playback or turning
off **Hold music** stops it. On speaker routes use the explicit control rather
than trying to speak over playback.

No music recording is distributed. The local development recording has no
redistribution grant recorded for this publication and was deliberately omitted.
Without an asset, calls still work and hold music is silent.

To use your own licensed recording, convert it to mono 24 kHz signed 16-bit
little-endian PCM, normalize it to a quiet level and fade the loop edges. Save
it locally as `ios/native/HoldMusic.pcm` before project generation. The generator
includes it only when present. Keep the recording outside Git and supply its
appropriate notice if distributing a build.
