extends Node

## Autoload : Audio
##
## Effets sonores générés à la volée : aucun fichier audio à fournir, donc aucun
## poids dans le build et rien à synchroniser entre l'éditeur et l'export.
## Un idle game se joue au son des chiffres qui montent : c'est la moitié du
## feedback.
##
## Godot n'expose pas les vibrations/haptiques : sur mobile, remplacer ou
## compléter par un plugin si le retour haptique est souhaité.

const SAMPLE_RATE := 22050
const VOICE_COUNT := 6

enum Kind { BLIP, CHIME, SWEEP, BUZZ, NOISE }

var sfx_volume: float = 0.55
var muted: bool = false

var _streams: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _next_voice: int = 0
var _audio_ok: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_audio_ok = DisplayServer.get_name() != "headless"
	if not _audio_ok:
		return
	for i in VOICE_COUNT:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_voices.append(p)
	_pregenerate()


func _pregenerate() -> void:
	_streams["click"] = _tone(760.0, 0.06, 0.55, Kind.BLIP)
	_streams["purchase"] = _chime([523.0, 784.0], 0.09, 0.5)
	_streams["upgrade"] = _chime([659.0, 988.0], 0.10, 0.5)
	_streams["achievement"] = _chime([523.0, 659.0, 784.0, 1046.0], 0.11, 0.55)
	_streams["prestige"] = _sweep(220.0, 1320.0, 0.65, 0.55)
	_streams["offline"] = _chime([392.0, 523.0, 659.0], 0.16, 0.5)
	_streams["error"] = _tone(150.0, 0.16, 0.4, Kind.BUZZ)
	_streams["combo"] = _tone(1100.0, 0.04, 0.3, Kind.BLIP)


func play(sound: String, pitch: float = 1.0) -> void:
	if muted or not _audio_ok or _voices.is_empty() or not _streams.has(sound):
		return
	var player := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	player.stream = _streams[sound]
	player.pitch_scale = clampf(pitch, 0.5, 2.0)
	player.volume_db = linear_to_db(clampf(sfx_volume, 0.0, 1.0))
	player.play()


func set_volume(value: float) -> void:
	sfx_volume = clampf(value, 0.0, 1.0)


func set_muted(value: bool) -> void:
	muted = value
	if muted:
		for p in _voices:
			p.stop()


# ------------------------------------------------------------------ synthèse

## Une note unique avec attaque/exponentielle.
func _tone(freq: float, duration: float, gain: float, kind: Kind) -> AudioStreamWAV:
	return _render(duration, func(t: float) -> float:
		var env: float = exp(-t * (5.0 / maxf(duration, 0.01)))
		match kind:
			Kind.BLIP:
				return sin(TAU * freq * t) * env
			Kind.BUZZ:
				return signf(sin(TAU * freq * t)) * env * 0.7
			Kind.NOISE:
				return randf_range(-1.0, 1.0) * env
			_:
				return sin(TAU * freq * t) * env
	, gain)


## Une arpège : chaque fréquence est jouée sur une fraction de la durée totale.
func _chime(freqs: Array, note_duration: float, gain: float) -> AudioStreamWAV:
	var total := note_duration * float(freqs.size())
	return _render(total, func(t: float) -> float:
		var idx: int = clampi(int(t / note_duration), 0, freqs.size() - 1)
		var local: float = t - float(idx) * note_duration
		var env: float = exp(-local * (5.0 / maxf(note_duration, 0.01)))
		# Légère sinusoïde de corps pour un son moins « pur », moins agressif.
		var f: float = freqs[idx]
		return (sin(TAU * f * local) + 0.3 * sin(TAU * f * 2.0 * local)) * env
	, gain)


## Un glissement de fréquence, pour les moments de victoire.
func _sweep(from_freq: float, to_freq: float, duration: float, gain: float) -> AudioStreamWAV:
	return _render(duration, func(t: float) -> float:
		var k: float = clampf(t / maxf(duration, 0.01), 0.0, 1.0)
		var freq: float = lerpf(from_freq, to_freq, k)
		var env: float = sin(PI * clampf(k, 0.0, 1.0))  # fondu entrant/sortant
		return sin(TAU * freq * t) * env
	, gain)


## Fabrique un AudioStreamWAV 16 bits mono à partir d'une fonction t -> [-1, 1].
func _render(duration: float, sample: Callable, gain: float) -> AudioStreamWAV:
	var count: int = maxi(1, int(SAMPLE_RATE * duration))
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i in count:
		var t := float(i) / float(SAMPLE_RATE)
		var v: float = clampf(float(sample.call(t)) * gain, -1.0, 1.0)
		bytes.encode_s16(i * 2, int(v * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = bytes
	return wav
