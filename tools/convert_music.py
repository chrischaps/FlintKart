import soundfile as sf

data, samplerate = sf.read("C:/Users/chris/dev/FlintKart/Kart_Racer_Groove_2026-02-17T042332.mp3")
print(f"Sample rate: {samplerate}")
channels = data.shape[1] if data.ndim > 1 else 1
print(f"Channels: {channels}")
print(f"Duration: {len(data) / samplerate:.1f}s")

sf.write("C:/Users/chris/dev/FlintKart/audio/race_music.ogg", data, samplerate, format="OGG", subtype="VORBIS")
print("Converted to audio/race_music.ogg")
