import soundfile as sf
d, r = sf.read("Kart_Racer_Groove_2026-02-17T042332.mp3")
sf.write("audio/race_music.ogg", d, r, format="OGG", subtype="VORBIS")
print(f"Converted: {r}Hz, {len(d)/r:.1f}s, {d.shape}")
