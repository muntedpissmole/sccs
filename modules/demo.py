"""Self-contained demo mode: dummy hardware data + a cycling Sonos playlist.

Enabled with ``[demo] enabled = true`` in sccs.conf. When active, real Sonos /
Victron / sensor hardware is not used; the UI is fed realistic simulated values
so customers can explore SCCS without a camper install.
"""

from __future__ import annotations

import logging
import math
import random
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger("sccs")

# Local static album art served by Flask (no external hosts, no data-URIs).
# Cover JPEGs live under static/images/demo/album-art/01.jpg … 10.jpg
# (sourced from public iTunes Search artwork URLs at demo build time).
_ALBUM_ART_STATIC_DIR = (
    Path(__file__).resolve().parent.parent / "static" / "images" / "demo" / "album-art"
)
_ALBUM_ART_URL_PREFIX = "/static/images/demo/album-art"

# ---------------------------------------------------------------------------
# Playlist — 10 electronic tracks, one artist each (melodic techno / deep /
# progressive / ambient). Metadata only; no audio is streamed. Album art is
# local JPEGs (see static/images/demo/album-art/).
# ---------------------------------------------------------------------------
DEMO_PLAYLIST: list[dict[str, Any]] = [
    {
        "track": "Strobe",
        "artist": "deadmau5",
        "album": "For Lack of a Better Name",
        "duration": 636,
        "art_file": "01.jpg",
    },
    {
        "track": "Opus",
        "artist": "Eric Prydz",
        "album": "OPUS",
        "duration": 545,
        "art_file": "02.jpg",
    },
    {
        "track": "Lace",
        "artist": "Lane 8",
        "album": "Little by Little",
        "duration": 372,
        "art_file": "03.jpg",
    },
    {
        "track": "The Less I Know",
        "artist": "Agoria",
        "album": "Drift",
        "duration": 348,
        "art_file": "04.jpg",
    },
    {
        "track": "Knights of the Jaguar",
        "artist": "DJ Rolando",
        "album": "Knights of the Jaguar",
        "duration": 401,
        "art_file": "05.jpg",
    },
    {
        "track": "Gosh",
        "artist": "Jamie xx",
        "album": "In Colour",
        "duration": 298,
        "art_file": "06.jpg",
    },
    {
        "track": "Ava",
        "artist": "Ólafur Arnalds",
        "album": "re:member",
        "duration": 312,
        "art_file": "07.jpg",
    },
    {
        "track": "Sunset",
        "artist": "The Midnight",
        "album": "Endless Summer",
        "duration": 356,
        "art_file": "08.jpg",
    },
    {
        "track": "Internal World",
        "artist": "Emancipator",
        "album": "Dusk to Dawn",
        "duration": 334,
        "art_file": "09.jpg",
    },
    {
        "track": "Hyperion",
        "artist": "RÜFÜS DU SOL",
        "album": "Solace",
        "duration": 389,
        "art_file": "10.jpg",
    },
]


def is_demo_enabled(config) -> bool:
    return bool(config.getboolean("demo", "enabled", fallback=False))


def _album_art_url(art_file: str | None) -> str | None:
    """Return a /static/... URL if the local art file exists on disk."""
    if not art_file:
        return None
    # Prevent path traversal — art files are basename-only.
    name = Path(art_file).name
    path = _ALBUM_ART_STATIC_DIR / name
    if not path.is_file():
        logger.warning("🎵 Demo album art missing: %s", path)
        return None
    return f"{_ALBUM_ART_URL_PREFIX}/{name}"


# ---------------------------------------------------------------------------
# Demo Sonos — playlist transport that auto-advances through 10 tracks
# ---------------------------------------------------------------------------


class DemoSonosManager:
    """Drop-in stand-in for SonosManager with a fixed cycling playlist."""

    SPEAKER_NAME = "Kitchen"

    def __init__(self, socketio, config):
        self.socketio = socketio
        self.config = config

        self.preferred_name = self.SPEAKER_NAME
        self.speakers = {self.SPEAKER_NAME: object()}
        self.current_speaker = self.SPEAKER_NAME
        self._last_default_saved = False

        self.playlist = [dict(t) for t in DEMO_PLAYLIST]
        for item in self.playlist:
            item["album_art"] = _album_art_url(item.get("art_file"))

        self._index = 0
        self._position = 0.0  # seconds into current track
        self._is_playing = True
        self._mute = False
        self._volume = config.getint("demo", "sonos_volume", fallback=42)
        self._volume = max(0, min(100, int(self._volume)))
        self._lock = threading.Lock()
        self._running = False
        self._thread: threading.Thread | None = None
        self._last_state: dict[str, Any] = {}
        self._tick_hz = 1.0

        logger.info(
            "🎵 DemoSonosManager ready — %d-track playlist (Jan Blomqvist / Christian Löffler style)",
            len(self.playlist),
        )

    # ---- lifecycle --------------------------------------------------------

    def start(self):
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(
            target=self._tick_loop, daemon=True, name="demo-sonos"
        )
        self._thread.start()
        self._broadcast_speakers()
        self._emit_state(force=True)
        logger.info("🎵 Demo Sonos playlist started on '%s'", self.SPEAKER_NAME)

    def stop(self):
        self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2)
        logger.debug("🎵 DemoSonosManager stopped")

    # ---- public API (matches SonosManager) --------------------------------

    def switch_speaker(self, name: str, *, make_default: bool = True) -> bool:
        if name not in self.speakers:
            return False
        self.current_speaker = name
        if make_default:
            self.preferred_name = name
            self._last_default_saved = True
        self._broadcast_speakers()
        self._emit_state(force=True)
        return True

    def execute_command(self, data: dict) -> dict:
        target = data.get("speaker") or self.current_speaker
        if target not in self.speakers:
            return {"error": f"No valid speaker: {target}"}

        cmd = data.get("command")
        value = data.get("value")
        if not cmd:
            return {"error": "No command provided"}

        with self._lock:
            if cmd == "playpause":
                self._is_playing = not self._is_playing
            elif cmd == "play":
                self._is_playing = True
            elif cmd == "pause":
                self._is_playing = False
            elif cmd == "next":
                self._advance(+1)
            elif cmd == "previous":
                # Restart track if past 3s, else previous
                if self._position > 3:
                    self._position = 0.0
                else:
                    self._advance(-1)
            elif cmd == "volume":
                if isinstance(value, (int, float)):
                    self._volume = max(0, min(100, int(value)))
            elif cmd == "mute":
                if value is None:
                    self._mute = not self._mute
                else:
                    self._mute = bool(value)
            elif cmd == "seek":
                if value is not None and 0 <= float(value) <= 1:
                    duration = self.playlist[self._index]["duration"]
                    self._position = float(duration) * float(value)
            else:
                return {"error": f"Unknown command: {cmd}"}

        self._emit_state(force=True)
        return {"success": True}

    def request_state(self):
        self._emit_state(force=True)

    def get_current_state(self) -> dict:
        with self._lock:
            state = self._build_state()
            self._last_state = state.copy()
            return state

    # ---- internals --------------------------------------------------------

    def _advance(self, delta: int):
        n = len(self.playlist)
        self._index = (self._index + delta) % n
        self._position = 0.0

    def _tick_loop(self):
        last = time.monotonic()
        while self._running:
            now = time.monotonic()
            dt = now - last
            last = now

            with self._lock:
                if self._is_playing:
                    track = self.playlist[self._index]
                    self._position += dt
                    if self._position >= track["duration"]:
                        # End of track → next song (wraps to 0 after last)
                        overflow = self._position - track["duration"]
                        self._advance(+1)
                        self._position = max(0.0, overflow)
                        logger.info(
                            "🎵 Demo playlist → %s — %s",
                            self.playlist[self._index]["artist"],
                            self.playlist[self._index]["track"],
                        )

            self._emit_state(force=False)
            time.sleep(1.0 / self._tick_hz)

    def _build_state(self) -> dict[str, Any]:
        track = self.playlist[self._index]
        position = int(self._position)
        duration = int(track["duration"])
        return {
            "speaker": self.current_speaker,
            "speakers": list(self.speakers.keys()),
            "volume": self._volume,
            "mute": self._mute,
            "is_playing": self._is_playing,
            "playing": self._is_playing,
            "track": track["track"],
            "title": track["track"],
            "artist": track["artist"],
            "album": track["album"],
            "album_art": track["album_art"],
            "position": position,
            "elapsed_seconds": position,
            "duration": duration,
            "duration_seconds": duration,
            "remaining_seconds": max(0, duration - position),
            "source": "demo",
            "playlist_index": self._index,
            "playlist_length": len(self.playlist),
        }

    def _emit_state(self, *, force: bool = False):
        with self._lock:
            state = self._build_state()
            # Skip noisy emits when nothing user-visible changed (except force)
            if not force and self._last_state:
                comparable = {
                    k: state.get(k)
                    for k in (
                        "track",
                        "artist",
                        "is_playing",
                        "mute",
                        "volume",
                        "position",
                        "speaker",
                    )
                }
                prev = {
                    k: self._last_state.get(k)
                    for k in comparable
                }
                if comparable == prev:
                    return
            self._last_state = state.copy()

        try:
            self.socketio.emit("sonos_update", state)
        except Exception as e:
            logger.debug("Demo sonos emit failed: %s", e)

    def _broadcast_speakers(self):
        data = {
            "speakers": list(self.speakers.keys()),
            "current": self.current_speaker,
            "preferred": self.preferred_name,
        }
        try:
            self.socketio.emit("sonos_speakers", data)
        except Exception as e:
            logger.debug("Demo sonos speakers emit failed: %s", e)


# ---------------------------------------------------------------------------
# Demo time helpers (Alexandra / configured timezone)
# ---------------------------------------------------------------------------


def _demo_local_now(config) -> datetime:
    """Local wall clock for the demo pin (default Australia/Melbourne)."""
    import zoneinfo

    tz_name = ""
    try:
        tz_name = (config.get("demo", "timezone", fallback="") or "").strip()
    except Exception:
        pass
    if not tz_name:
        try:
            tz_name = (
                config.get("gps", "fallback_timezone", fallback="Australia/Melbourne")
                or "Australia/Melbourne"
            )
        except Exception:
            tz_name = "Australia/Melbourne"
    try:
        return datetime.now(zoneinfo.ZoneInfo(tz_name))
    except Exception:
        return datetime.now().astimezone()


def _smoothstep(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


# ---------------------------------------------------------------------------
# Demo Victron — daily battery / solar cycle
# ---------------------------------------------------------------------------


class DemoVictronManager:
    """Drop-in stand-in for VictronManager with a clear daily power story.

    Day: solar curve charges the bank up to ~100% by mid-afternoon.
    Night: no solar; battery drains to roughly 60–70% by morning.
    Yield resets at local midnight.
    """

    # Overnight floor (target SoC at sunrise) — mild day-to-day wander in 60–70.
    _NIGHT_SOC_LOW = 65.0
    _NIGHT_SOC_SPAN = 5.0  # ± around the centre

    def __init__(self, socketio, config, phase_manager=None):
        self.socketio = socketio
        self.config = config
        self.phase_manager = phase_manager

        # Fake BLE MACs shown on the Victron system tile (not real hardware).
        self.shunt_address = "c4:d3:6a:12:8f:41"
        self.mppt_address = "c4:d3:6a:9b:e2:17"

        self._running = False
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._t0 = time.time()
        self._yield_today = float(config.getfloat("demo", "solar_yield_kwh", fallback=2.4) or 2.4)
        seed_soc = float(config.getfloat("demo", "battery_soc", fallback=78) or 78)
        self._soc = max(55.0, min(100.0, seed_soc))
        # Night base load ~5 A; occasional short spikes (fridge compressor etc.)
        self._night_load_a = 5.0
        self._load_spike_until = 0.0
        self._load_spike_extra = 0.0
        # Stable overnight low for "today" (re-rolled at local midnight)
        self._night_floor = self._roll_night_floor()
        self._last_local_date = self._local_now().date()

        # Snap SoC onto the daily curve so a restart mid-day looks right
        self._soc = self._target_soc(self._local_now())
        self.state = self._build_state(*self._power_snapshot())
        logger.info("🔋 DemoVictronManager ready (dummy SmartShunt + MPPT)")

    def _roll_night_floor(self) -> float:
        """Pick tonight's morning SoC target in the 60–70% band."""
        return self._NIGHT_SOC_LOW + random.uniform(
            -self._NIGHT_SOC_SPAN, self._NIGHT_SOC_SPAN
        )
    def start(self):
        if self._running:
            return
        self._running = True
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._loop, daemon=True, name="demo-victron"
        )
        self._thread.start()
        logger.info("🔋 Demo Victron simulation started")

    def stop(self):
        self._running = False
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2)

    def get_state(self):
        s = self.state.copy()
        s["stale"] = False
        return s

    def reset_daily_generation(self):
        self._yield_today = 0.0
        logger.info("🔋 Demo Victron daily yield reset")

    def _local_now(self) -> datetime:
        return _demo_local_now(self.config)

    def _phase_name(self) -> str:
        if self.phase_manager is not None:
            try:
                return str(self.phase_manager.get_phase() or "").strip().title()
            except Exception:
                pass
        return ""

    def _sun_hours(self, local: datetime) -> tuple[float, float]:
        """Approximate sunrise/sunset decimal hours for solar curve."""
        # Prefer PhaseManager cached sun times when available
        if self.phase_manager is not None:
            try:
                times = self.phase_manager.get_phase_times() or {}
                # Keys vary: sunrise/sunset as "HH:MM AM" or ISO
                for key_rise, key_set in (
                    ("sunrise", "sunset"),
                    ("sunrise_time", "sunset_time"),
                ):
                    rise_s = times.get(key_rise)
                    set_s = times.get(key_set)
                    if rise_s and set_s:
                        rh = self._parse_time_to_hours(str(rise_s), local)
                        sh = self._parse_time_to_hours(str(set_s), local)
                        if rh is not None and sh is not None:
                            return rh, sh
            except Exception:
                pass
        # Alexandra, Vic — rough seasonal midpoint (good enough for demo)
        return 6.75, 17.75

    @staticmethod
    def _parse_time_to_hours(value: str, local: datetime) -> float | None:
        value = (value or "").strip()
        if not value:
            return None
        for fmt in ("%I:%M %p", "%I:%M%p", "%H:%M", "%H:%M:%S"):
            try:
                t = datetime.strptime(value, fmt)
                return t.hour + t.minute / 60.0 + t.second / 3600.0
            except ValueError:
                continue
        return None

    def _target_soc(self, local: datetime) -> float:
        """Ideal SoC for this wall-clock moment (daily charge / overnight drain).

        - Sunrise → mid-afternoon: climb from night floor (~60–70%) to 100%
        - Mid-afternoon → sunset: sit near full
        - Sunset → next sunrise: ease from ~100% down to night floor
        """
        hour = local.hour + local.minute / 60.0 + local.second / 3600.0
        sunrise_h, sunset_h = self._sun_hours(local)
        floor = self._night_floor
        # Full by ~65% of the solar day (early–mid afternoon)
        peak_h = sunrise_h + 0.65 * max(0.5, sunset_h - sunrise_h)
        peak_h = min(peak_h, sunset_h - 0.35)

        if sunrise_h <= hour < peak_h:
            x = (hour - sunrise_h) / max(0.25, peak_h - sunrise_h)
            return floor + (100.0 - floor) * _smoothstep(x)
        if peak_h <= hour < sunset_h:
            # Soft float near 100% with a hint of late-day use
            x = (hour - peak_h) / max(0.15, sunset_h - peak_h)
            return 100.0 - 2.5 * _smoothstep(x)
        # Night: from sunset → midnight → sunrise
        night_len = max(0.5, (24.0 - sunset_h) + sunrise_h)
        if hour >= sunset_h:
            elapsed_night = hour - sunset_h
        else:
            elapsed_night = (24.0 - sunset_h) + hour
        x = elapsed_night / night_len
        # Start night slightly under full if we floated to ~97.5
        night_start = 97.5
        return night_start + (floor - night_start) * _smoothstep(x)

    def _power_snapshot(self) -> tuple[float, float, float, str]:
        """Return (solar_w, solar_a, battery_current_a, charge_state).

        battery_current_a is signed shunt current: negative = discharging.
        Currents are sized so SoC tracks the daily target curve.
        """
        elapsed = time.time() - self._t0
        local = self._local_now()
        hour = local.hour + local.minute / 60.0 + local.second / 3600.0
        phase = self._phase_name()
        sunrise_h, sunset_h = self._sun_hours(local)

        is_night = (
            phase == "Night"
            or hour < sunrise_h
            or hour >= sunset_h
        )
        if phase == "Evening" and hour >= sunset_h - 0.25:
            is_night = True

        capacity_ah = 200.0
        target = self._target_soc(local)
        # Desired current to chase the curve over the next few minutes
        # (UI updates every 3 s; use a ~15 min time constant so it eases, not jumps)
        tau_h = 0.25
        chase_a = ((target - self._soc) / 100.0) * capacity_ah / tau_h

        if is_night:
            solar_w = 0.0
            solar_a = 0.0
            wander = 0.35 * math.sin(elapsed / 180.0) + 0.15 * math.sin(elapsed / 47.0)
            now_m = time.monotonic()
            if now_m >= self._load_spike_until and random.random() < 0.04:
                self._load_spike_extra = random.uniform(1.5, 3.0)
                self._load_spike_until = now_m + random.uniform(30.0, 90.0)
            if now_m >= self._load_spike_until:
                self._load_spike_extra = 0.0
            noise = random.uniform(-0.12, 0.12)
            # Discharge toward morning floor; keep a believable 3.5–9 A draw
            load_a = max(3.5, min(9.0, abs(min(chase_a, -3.5)) + wander * 0.2 + self._load_spike_extra + noise))
            # If already at/under floor, idle near zero discharge
            if self._soc <= target + 0.5:
                load_a = max(2.0, 3.0 + wander * 0.3 + noise)
            battery_a = -load_a
            charge = "Off"
            return solar_w, solar_a, battery_a, charge

        # --- Daytime solar curve (half-sine between sunrise and sunset) ---
        day_len = max(0.5, sunset_h - sunrise_h)
        x = (hour - sunrise_h) / day_len
        x = max(0.0, min(1.0, x))
        solar_factor = math.sin(math.pi * x)
        cloud = 0.88 + 0.12 * math.sin(elapsed / 300.0)
        peak_w = 380.0  # enough array to refill the bank over a demo day
        solar_w = max(0.0, solar_factor * cloud * peak_w)
        if solar_w < 5.0:
            solar_w = 0.0

        v_nom = 13.2
        solar_a = solar_w / v_nom if solar_w > 0 else 0.0

        day_load = 3.5 + 1.5 * math.sin(elapsed / 90.0) + random.uniform(-0.2, 0.4)
        day_load = max(2.0, min(8.0, day_load))

        # Prefer chase current when charging hard toward 100%; else PV − load
        if chase_a > 0.5 and solar_a > 0:
            # Net charge limited by available solar headroom after house load
            battery_a = min(chase_a, max(0.0, solar_a - day_load * 0.35))
            # Still show house load when float/full
            if self._soc >= 99.0:
                battery_a = max(-day_load * 0.4, solar_a - day_load)
        else:
            battery_a = solar_a - day_load

        if solar_w <= 0:
            charge = "Off"
        elif self._soc >= 97 and battery_a > -0.5:
            charge = "Float"
        elif battery_a > 0.3:
            charge = "Bulk"
        else:
            charge = "Off"

        return solar_w, solar_a, battery_a, charge

    def _build_state(
        self, solar_w: float, solar_a: float, battery_a: float, charge: str
    ) -> dict[str, Any]:
        now = datetime.now(timezone.utc).isoformat()
        voltage = 12.55 + (self._soc / 100.0) * 1.05
        if battery_a > 0.5:
            voltage += 0.08
        elif battery_a < -0.5:
            voltage -= 0.06
        voltage = round(voltage, 2)

        # TTG only while discharging
        if battery_a < -0.3:
            # hours remaining ≈ (usable Ah * SoC) / |I|
            usable_ah = 200.0 * (self._soc / 100.0) * 0.85
            ttg = int(max(15, (usable_ah / abs(battery_a)) * 60))
        else:
            ttg = None

        consumed = round(max(2.0, (100.0 - self._soc) * 1.1), 1)
        temp = round(18.0 + 6.0 * max(0.0, solar_w / 320.0) + random.uniform(-0.2, 0.2), 1)

        return {
            "stale": False,
            "soc": round(self._soc, 1),
            "voltage": voltage,
            "current_a": round(battery_a, 2),
            "consumed_ah": consumed,
            "time_to_go_mins": ttg,
            "solar_power_w": round(solar_w, 0),
            "solar_current_a": round(solar_a, 2),
            "yield_today_kwh": round(self._yield_today, 2),
            "charge_state": charge,
            "temperature": temp,
            "last_update": now,
            "source": "demo",
            "shunt": {
                "configured": True,
                "address": self.shunt_address,
                "connected": True,
                "stale": False,
                "name": "SmartShunt",
                "rssi": -55 + random.randint(-3, 3),
                "model_name": "SmartShunt 500A",
                "soc": round(self._soc, 1),
                "voltage": voltage,
                "current": round(battery_a, 2),
                "remaining_mins": ttg,
                "consumed_ah": consumed,
                "temperature": temp,
                "last_update": now,
            },
            "mppt": {
                "configured": True,
                "address": self.mppt_address,
                "connected": True,
                "stale": False,
                "name": "SmartSolar",
                "rssi": -58 + random.randint(-3, 3),
                "model_name": "SmartSolar 100/30",
                "charge_state": charge,
                "battery_voltage": voltage,
                "battery_charging_current": round(max(0.0, solar_a), 2),
                "yield_today_wh": int(self._yield_today * 1000),
                "solar_power": round(solar_w, 0),
                "last_update": now,
            },
        }

    def _loop(self):
        while not self._stop.wait(3.0):
            try:
                self._tick()
            except Exception as e:
                logger.debug("Demo victron tick: %s", e)

    def _tick(self):
        local = self._local_now()
        today = local.date()
        if today != self._last_local_date:
            # Local midnight rollover: new overnight floor + yield reset
            self._last_local_date = today
            self._night_floor = self._roll_night_floor()
            self.reset_daily_generation()

        solar_w, solar_a, battery_a, charge = self._power_snapshot()

        # Blend Ah integration with the daily target so SoC always tells the story
        # (reaches ~100% by afternoon, ~60–70% by morning) without looking stepped.
        dt_h = 3.0 / 3600.0
        capacity_ah = 200.0
        integrated = self._soc + (battery_a * dt_h / capacity_ah) * 100.0
        target = self._target_soc(local)
        # Heavy ease toward the curve (demo readability > perfect physics)
        self._soc = 0.35 * integrated + 0.65 * target
        self._soc = max(55.0, min(100.0, self._soc))

        if solar_w > 0:
            # Mild accel so yield_today moves during a short demo session
            self._yield_today += (solar_w * dt_h / 1000.0) * 1.5

        self.state = self._build_state(solar_w, solar_a, battery_a, charge)
        try:
            self.socketio.emit("victron_update", self.get_state())
        except Exception:
            pass

# ---------------------------------------------------------------------------
# Demo sensors — climate + water without ESP32 / 1-Wire
# ---------------------------------------------------------------------------


class DemoSensorManager:
    """Drop-in stand-in for SensorManager with drifting dummy readings.

    Water tank: full (100%) at local midnight, then slowly used down to ~20%
    over the following day (refills again at the next midnight).
    """

    def __init__(self, config, send_command_func, socketio):
        self.config = config
        self.send_command = send_command_func  # unused
        self.socketio = socketio
        self.running = False
        self.thread: threading.Thread | None = None
        self._t0 = time.time()
        self.WATER_CAPACITY_LITRES = config.getfloat("tanks", "water_litres", fallback=120) or 120
        # Truthy IDs so /api/sensors and climate tile treat fridge/freezer as
        # always configured (same attrs real SensorManager exposes).
        self.OUTSIDE_TEMP_ID = "demo-outside"
        self.FRIDGE_TEMP_ID = "demo-fridge"
        self.FREEZER_TEMP_ID = "demo-freezer"
        self.last_reading: dict = {}
        logger.info("🌡️ DemoSensorManager ready (dummy climate + water)")

    def _local_now(self) -> datetime:
        return _demo_local_now(self.config)

    def _water_percent(self, local: datetime) -> float:
        """100% at midnight → ~20% by end of day, with small usage wobble."""
        day_frac = (
            local.hour * 3600.0 + local.minute * 60.0 + local.second + local.microsecond / 1e6
        ) / 86400.0
        # Smooth linear use over the day
        water = 100.0 - 80.0 * day_frac  # 100 → 20
        # Gentle “showers / dishes” undulation (does not reverse the day trend)
        water += 2.0 * math.sin(day_frac * math.pi * 6.0)
        water += 0.8 * math.sin(time.time() / 45.0)
        return max(18.0, min(100.0, water))
    def start(self):
        if self.running:
            return
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True, name="demo-sensors")
        self.thread.start()

    def stop(self):
        self.running = False
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=2)

    def _outside_from_weather(self) -> float | None:
        """Match climate tile big number to Alexandra weather (not a fake sensor)."""
        try:
            from weather import get_weather_status

            t = get_weather_status().get("temperature_c")
            if t is not None:
                return round(float(t), 1)
        except Exception:
            pass
        return None

    def update_sensors(self):
        elapsed = time.time() - self._t0
        local = self._local_now()
        # Outside air follows scraped Alexandra weather so the headline temp
        # matches the forecast chart hover. Fridge/freezer stay simulated.
        outside = self._outside_from_weather()
        fridge = 4.2 + 0.4 * math.sin(elapsed / 50.0)
        freezer = -16.5 + 0.6 * math.sin(elapsed / 70.0)
        water = self._water_percent(local)

        sensor_data = {
            "water_percent": round(water, 0),
            "water_capacity_litres": self.WATER_CAPACITY_LITRES,
            "temp_c": outside,
            "outside_temp_c": outside,
            "fridge_temp_c": round(fridge, 1),
            "freezer_temp_c": round(freezer, 1),
            "fridge_configured": True,
            "freezer_configured": True,
            "temp_valid": outside is not None,
            "source": "demo",
        }
        self.last_reading = sensor_data
        try:
            self.socketio.emit("sensor_update", sensor_data)
        except Exception:
            pass
    def _loop(self):
        interval = self.config.getfloat("sensors", "update_interval", fallback=5.0)
        while self.running:
            try:
                self.update_sensors()
            except Exception as e:
                logger.error("Demo sensor loop error: %s", e)
            time.sleep(interval)


# ---------------------------------------------------------------------------
# Demo GPS seed — fixed "van parked" location without serial hardware
# ---------------------------------------------------------------------------


class _DemoSerial:
    """Minimal stand-in so GPSModule.get_state() reports hardware present."""

    is_open = True
    port = "demo"

    def close(self):
        self.is_open = False


def seed_demo_gps(gps_module, config) -> None:
    """Inject a stable fix: Alexandra, Victoria (coords drive weather + sun times)."""
    # Fixed pin — Alexandra VIC (ignore stale "Demo Campsite" conf leftovers)
    lat = config.getfloat("demo", "latitude", fallback=None)
    lon = config.getfloat("demo", "longitude", fallback=None)
    if lat is None:
        lat = config.getfloat("gps", "fallback_latitude", fallback=-37.191)
    if lon is None:
        lon = config.getfloat("gps", "fallback_longitude", fallback=145.711)

    suburb_raw = (config.get("demo", "suburb", fallback="") or "").strip()
    if not suburb_raw or suburb_raw.lower() in {
        "demo campsite",
        "democampsite",
        "demo",
    }:
        suburb_raw = (config.get("gps", "fallback_name", fallback="") or "").strip()
    if not suburb_raw or suburb_raw.lower() in {
        "demo campsite",
        "democampsite",
        "demo",
    }:
        suburb_raw = "Alexandra"
    # Canonical display name
    if suburb_raw.lower().startswith("alexandra"):
        suburb = "Alexandra"
    else:
        suburb = suburb_raw

    tz = (config.get("demo", "timezone", fallback="") or "").strip()
    if not tz:
        tz = (
            gps_module.get_fallback_timezone()
            if hasattr(gps_module, "get_fallback_timezone")
            else "Australia/Melbourne"
        )

    # Pretend a GPS receiver is open so get_state() keeps our live fix fields
    # instead of swapping in the offline fallback blob.
    gps_module.serial = _DemoSerial()

    gps_module.state.update(
        {
            "latitude": float(lat),
            "longitude": float(lon),
            "altitude_m": 320.0,
            "suburb": suburb,
            "last_known_suburb": suburb,
            "timezone": tz,
            "using_fallback": False,
            "force_no_fix": False,
            "force_no_hardware": False,
            "satellites": 11,
            "fix_quality": 1,
            "hdop": 0.9,
            "speed_kmh": 0.0,
        }
    )

    # Skip online reverse-geocode so Nominatim cannot rename the pin.
    try:
        gps_module.geolocator = None
    except Exception:
        pass

    if hasattr(gps_module, "_update_sun_times"):
        try:
            gps_module._update_sun_times()
        except Exception as e:
            logger.debug("Demo sun times: %s", e)

    # Re-assert suburb after sun calc (it may emit state without our label)
    gps_module.state["suburb"] = suburb
    gps_module.state["last_known_suburb"] = suburb
    gps_module.state["using_fallback"] = False

    def _broadcast_loop():
        interval = config.getfloat("gps", "broadcast_interval", fallback=2.0) or 2.0
        while not getattr(gps_module, "_stop_event", threading.Event()).is_set():
            try:
                try:
                    import zoneinfo

                    now_utc = datetime.now(timezone.utc)
                    local_tz = zoneinfo.ZoneInfo(gps_module.state.get("timezone") or tz)
                    local_dt = now_utc.astimezone(local_tz)
                    gps_module.state["utc_time"] = now_utc.isoformat()
                    gps_module.state["local_time"] = local_dt.strftime("%I:%M:%S %p")
                    gps_module.state["date"] = local_dt.strftime("%A, %d %B %Y")
                except Exception:
                    pass
                # Pin the label every tick so nothing else renames it
                gps_module.state["suburb"] = suburb
                gps_module.state["last_known_suburb"] = suburb
                gps_module.state["using_fallback"] = False
                gps_module.state["latitude"] = float(lat)
                gps_module.state["longitude"] = float(lon)
                gps_module.socketio.emit("gps_update", gps_module.get_state())
            except Exception:
                pass
            if gps_module._stop_event.wait(interval):
                break

    if not hasattr(gps_module, "_stop_event") or gps_module._stop_event is None:
        gps_module._stop_event = threading.Event()
    gps_module._stop_event.clear()

    t = threading.Thread(target=_broadcast_loop, daemon=True, name="demo-gps")
    gps_module._reader_thread = t
    t.start()
    logger.info(
        "🛰️ Demo GPS seeded at %s (%.4f, %.4f)",
        suburb,
        float(lat),
        float(lon),
    )


# ---------------------------------------------------------------------------
# Activity simulator — reeds only (lights react via normal policy when open)
# ---------------------------------------------------------------------------


class DemoActivitySimulator:
    """Simulate reed open/close only.

    No random scenes, relay bursts, or slider nudges. Day/Evening/Night stay
    with PhaseManager (system clock). Opening a reed still drives real lighting
    policy for that reed — that is automation, not a separate light simulator.

    Rooftop tent is schedule-driven (not random): opens sometime in the
    afternoon and closes in the morning (local demo timezone).
    """

    # Reed name in sccs.conf [reeds]
    TENT_REED = "rooftop_tent"

    def __init__(self, runtime, config):
        self.runtime = runtime
        self.config = config
        self._running = False
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

        # Simulated reed closed map (True = closed). Written into WorldStore
        # as live sensor state — never as reed_forces.
        self._reed_closed: dict[str, bool] = {}

        self._enabled = config.getboolean("demo", "activity", fallback=True)
        # Default: change reeds every 30–60 minutes; always keep ≥1 open
        self._reed_min = max(60.0, float(config.getfloat("demo", "reed_min_s", fallback=1800) or 1800))
        self._reed_max = max(self._reed_min, float(config.getfloat("demo", "reed_max_s", fallback=3600) or 3600))
        self._max_open = max(1, int(config.getint("demo", "max_open_reeds", fallback=3) or 3))
        self._min_open = 1

        # Daily tent schedule (local hours); re-rolled at local midnight
        self._tent_open_hour = 14.0
        self._tent_close_hour = 8.0
        self._tent_schedule_date = None
        self._roll_tent_schedule()
    # ---- lifecycle --------------------------------------------------------

    def start(self):
        if not self._enabled:
            logger.info("🎬 Demo activity simulator disabled ([demo] activity = false)")
            return
        if self._running:
            return
        self._running = True
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._loop, daemon=True, name="demo-activity"
        )
        self._thread.start()
        logger.info(
            "🎬 Demo reed simulator started (every %.0f–%.0fs, ≥1 always open)",
            self._reed_min,
            self._reed_max,
        )

    def stop(self):
        self._running = False
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=3)
        self._thread = None

    def _current_phase(self) -> str:
        """Live phase from PhaseManager (clock / sun), never forced by the demo."""
        pm = getattr(self.runtime, "phase_manager", None)
        if pm is not None:
            try:
                return str(pm.get_phase() or "Day").strip().title()
            except Exception:
                pass
        return "Day"

    def _local_now(self) -> datetime:
        return _demo_local_now(self.config)

    def _roll_tent_schedule(self) -> None:
        """Pick open/close times for "today" — afternoon open, morning close."""
        # Open sometime 13:00–16:00; close 07:00–09:00
        self._tent_open_hour = random.uniform(13.0, 16.0)
        self._tent_close_hour = random.uniform(7.0, 9.0)
        try:
            self._tent_schedule_date = self._local_now().date()
        except Exception:
            self._tent_schedule_date = None
        logger.info(
            "⛺ Demo rooftop tent schedule: open ~%s, close ~%s (local)",
            self._fmt_hour(self._tent_open_hour),
            self._fmt_hour(self._tent_close_hour),
        )

    @staticmethod
    def _fmt_hour(h: float) -> str:
        hh = int(h) % 24
        mm = int(round((h - int(h)) * 60)) % 60
        return f"{hh:02d}:{mm:02d}"

    def _tent_should_be_open(self, local: datetime | None = None) -> bool:
        """True from afternoon open time through overnight until morning close."""
        local = local or self._local_now()
        if self._tent_schedule_date is not None and local.date() != self._tent_schedule_date:
            self._roll_tent_schedule()
        hour = local.hour + local.minute / 60.0 + local.second / 3600.0
        open_h = self._tent_open_hour
        close_h = self._tent_close_hour
        # Open window wraps midnight: [open_h, 24) U [0, close_h)
        if open_h <= hour or hour < close_h:
            return True
        return False

    def _sync_rooftop_tent(self) -> None:
        """Drive rooftop_tent from the daily schedule (not random activity)."""
        if self.TENT_REED not in self.runtime.compiled.reed_names:
            return
        if self.TENT_REED not in self._reed_closed:
            self._reed_closed[self.TENT_REED] = True
        want_open = self._tent_should_be_open()
        is_closed = self._reed_closed.get(self.TENT_REED, True)
        if want_open and is_closed:
            self._set_reed(self.TENT_REED, closed=False)
        elif not want_open and not is_closed:
            self._set_reed(self.TENT_REED, closed=True)

    # ---- main loop --------------------------------------------------------

    def _loop(self):
        # Let bootstrap / first reconcile settle.
        if self._stop.wait(4.0):
            return

        try:
            self._bootstrap()
        except Exception as e:
            logger.warning("Demo activity bootstrap failed: %s", e)

        next_reed = time.monotonic() + random.uniform(self._reed_min, self._reed_max)

        while not self._stop.is_set():
            now = time.monotonic()
            try:
                # Tent schedule checked every loop (~1s) for prompt open/close
                self._sync_rooftop_tent()
                if now >= next_reed:
                    self._tick_reeds()
                    next_reed = now + random.uniform(self._reed_min, self._reed_max)
            except Exception as e:
                logger.warning("Demo activity tick error: %s", e)

            # Short sleep so stop() is responsive
            self._stop.wait(1.0)
    def _bootstrap(self):
        """All reeds closed, then a sensible starting tableau (no force overrides)."""
        # Ensure no leftover forced phase — clock-driven PhaseManager owns phases.
        try:
            self.runtime.force_phase(None)
        except Exception:
            pass
        # Drop any force overrides so Settings never shows "Forced open/closed".
        try:
            self.runtime.world.clear_all_reed_forces()
        except Exception:
            pass

        names = list(self.runtime.compiled.reed_names)
        if not names:
            logger.warning("Demo activity: no reeds configured — lighting sim limited")
            return

        for name in names:
            self._reed_closed[name] = True
        self._publish_reeds(transitioned=list(names))

        time.sleep(0.8)

        # Kitchen in use — panel open (and ambient comes up because a reed is open).
        self._set_reed("kitchen_panel", closed=False)
        time.sleep(1.0)
        if "kitchen_bench" in self._reed_closed:
            self._set_reed("kitchen_bench", closed=False)

        # Rooftop tent follows afternoon/morning schedule from the start
        self._sync_rooftop_tent()

        logger.info(
            "🎬 Demo tableau: phase=%s (clock) open=%s",
            self._current_phase(),
            [n for n, c in self._reed_closed.items() if not c] or "none",
        )
    # ---- actions (all via real runtime policy) ----------------------------

    def _publish_reeds(self, *, transitioned: list[str] | None = None):
        """Push simulated reed map as live hardware state (not reed_forces)."""
        names = list(self.runtime.compiled.reed_names)
        reeds = {n: bool(self._reed_closed.get(n, True)) for n in names}
        # Keep forces empty so the UI shows normal Open/Closed.
        try:
            self.runtime.world.clear_all_reed_forces()
        except Exception:
            pass
        changed = list(transitioned or [])
        try:
            self.runtime.on_reeds_updated(reeds, changed)
        except Exception as e:
            logger.warning("Demo reed publish failed: %s", e)

    def _set_reed(self, name: str, *, closed: bool):
        if name not in self.runtime.compiled.reed_names:
            return
        # Honour kitchen_bench interlock for realistic open sequences:
        # opening the bench while the panel is closed does nothing useful.
        if not closed and name == "kitchen_bench":
            if self._reed_closed.get("kitchen_panel", True):
                self._set_reed("kitchen_panel", closed=False)
                time.sleep(0.6)

        prev = self._reed_closed.get(name)
        self._reed_closed[name] = closed
        transitioned = [name]

        # Closing kitchen_panel also effectively interlocks the bench.
        if closed and name == "kitchen_panel" and "kitchen_bench" in self._reed_closed:
            if not self._reed_closed.get("kitchen_bench", True):
                self._reed_closed["kitchen_bench"] = True
                transitioned.append("kitchen_bench")
                logger.info("🚪 Demo reed kitchen_bench → closed (panel closed)")

        self._publish_reeds(transitioned=transitioned)

        if prev is None or prev != closed:
            state = "closed" if closed else "OPEN"
            logger.info("🚪 Demo reed %s → %s", name, state)

    def _open_count(self) -> int:
        return sum(1 for c in self._reed_closed.values() if not c)

    def _tick_reeds(self):
        names = list(self.runtime.compiled.reed_names)
        if not names:
            return

        # Tent is schedule-only — keep it out of random open/close pools
        free_names = [n for n in names if n != self.TENT_REED]
        if not free_names:
            return

        phase = self._current_phase()
        open_names = [
            n for n, c in self._reed_closed.items()
            if not c and n != self.TENT_REED
        ]
        closed_names = [
            n for n, c in self._reed_closed.items()
            if c and n != self.TENT_REED
        ]

        roll = random.random()

        # Prefer having 1–max_open free reeds open so ambient + reed lights show.
        # (Tent may also be open on schedule; it doesn't count against random pool.)
        if not open_names or (len(open_names) < self._max_open and roll < 0.55):
            candidates = list(closed_names) or free_names
            weights = []
            for n in candidates:
                w = 1.0
                if n == "kitchen_panel":
                    w = 2.5
                elif n == "kitchen_bench":
                    w = 1.8 if not self._reed_closed.get("kitchen_panel", True) else 0.4
                elif n == "storage_panel":
                    w = 1.4
                elif n == "rear_drawer":
                    w = 1.2
                weights.append(w)
            pick = random.choices(candidates, weights=weights, k=1)[0]
            self._set_reed(pick, closed=False)
            return

        if open_names and roll < 0.70:
            pick = random.choice(open_names)
            free_open = len(open_names)
            if free_open <= self._min_open:
                others = [n for n in free_names if n != pick]
                if others:
                    self._set_reed(pick, closed=True)
                    time.sleep(0.4)
                    self._set_reed(random.choice(others), closed=False)
                return
            self._set_reed(pick, closed=True)
            return

        if closed_names and roll > 0.92 and len(open_names) < self._max_open:
            burst = random.sample(closed_names, k=min(2, len(closed_names)))
            for n in burst:
                if len([x for x, c in self._reed_closed.items() if not c and x != self.TENT_REED]) >= self._max_open:
                    break
                self._set_reed(n, closed=False)
                time.sleep(0.5)

# ---------------------------------------------------------------------------
# Demo kitchen touchscreen — online panel, all controls local (no SSH)
# ---------------------------------------------------------------------------

_DEMO_KITCHEN_SCREEN = {
    "friendly": "Kitchen",
    "linked_reed": "kitchen_panel",
    "host": "10.10.10.10",
    "username": "joel",
    # Adjustable brightness path so the slider is shown
    "brightness_path": "/sys/class/backlight/rpi_backlight/brightness",
    "icon": "fa-utensils",
    "phase_brightness": {"day": 100, "evening": 30, "night": 5},
    "blank_path": None,
    "mac": None,
}


def install_demo_screens(runtime) -> None:
    """Register a Kitchen touchscreen and simulate wake/sleep/brightness/refresh."""
    from actuators.screens import ScreenActuator

    # Ensure kitchen is in the compiled screen map
    screens = runtime.compiled.screens
    if "kitchen" not in screens:
        screens["kitchen"] = dict(_DEMO_KITCHEN_SCREEN)
        logger.info("🖥️ Demo kitchen touchscreen added to config")
    else:
        # Keep friendly name clean
        screens["kitchen"]["friendly"] = screens["kitchen"].get("friendly") or "Kitchen"

    if not runtime.screen_actuator:
        runtime.screen_actuator = ScreenActuator(screens, runtime.compiled)
    else:
        # Merge kitchen into existing actuator map
        runtime.screen_actuator._screens = screens
        if "kitchen" not in runtime.screen_actuator._observed:
            runtime.screen_actuator._observed["kitchen"] = 80

    sa = runtime.screen_actuator
    if getattr(sa, "_demo_screens_installed", False):
        return

    # Per-screen simulated state
    demo_state: dict[str, dict] = {}
    for name in screens:
        pct = int(sa._observed.get(name, 0) or 0)
        if name == "kitchen" and pct <= 0:
            pct = 80  # start awake
            sa._observed[name] = pct
        demo_state[name] = {
            "online": True,
            "latency_ms": random.randint(6, 18),
            "pct": pct,
            "ssh_passwordless": True,
        }

    def _set_pct(name: str, brightness_pct: int) -> None:
        brightness_pct = max(0, min(100, int(brightness_pct)))
        sa._observed[name] = brightness_pct
        st = demo_state.setdefault(
            name,
            {"online": True, "latency_ms": 10, "pct": 0, "ssh_passwordless": True},
        )
        st["pct"] = brightness_pct
        st["online"] = True
        logger.info(
            "🖥️ Demo screen %s → %s%%",
            screens.get(name, {}).get("friendly", name),
            brightness_pct,
        )

    def set_screen(name: str, brightness_pct: int):
        if name not in screens:
            return
        _set_pct(name, brightness_pct)
        # No SSH thread

    def test_connectivity(name: str, timeout: float = 3.0) -> dict:
        st = demo_state.get(name)
        if not st:
            return {"online": False, "error": "No config"}
        # Tiny jitter on latency for a live feel
        st["latency_ms"] = max(4, min(40, st.get("latency_ms", 10) + random.randint(-2, 3)))
        pct = int(st.get("pct") or 0)
        return {
            "online": True,
            "latency": st["latency_ms"],
            "ssh_passwordless": True,
            "ssh_error": None,
            "brightness": pct,
            "brightness_pct": pct,
            "on": pct > 0,
        }

    def manual_toggle(
        name: str,
        force_on: bool | None = None,
        brightness_pct: int | None = None,
    ):
        if name not in screens:
            return
        if brightness_pct is not None:
            _set_pct(name, brightness_pct)
            return
        if force_on is None:
            force_on = (sa._observed.get(name, 0) or 0) <= 0
        if not force_on:
            _set_pct(name, 0)
            return
        conf = screens.get(name) or {}
        levels = conf.get("phase_brightness") or {}
        fallback = int(max(levels.values(), default=100) if levels else 100)
        # Prefer current phase level when available
        pm = getattr(runtime, "phase_manager", None)
        if pm is not None:
            try:
                phase = str(pm.get_phase() or "day").strip().lower()
                if phase in levels:
                    fallback = int(levels[phase])
            except Exception:
                pass
        _set_pct(name, max(fallback, 1))

    def shutdown_all(join_timeout: float = 15.0):
        # Demo: sleep panels only — never SSH poweroff remotes or host
        for name in list(screens.keys()):
            _set_pct(name, 0)
        logger.info("🖥️ Demo screen shutdown_all — panels slept (no remote poweroff)")

    def _probe_all():
        # No background SSH probes
        return

    def _apply(name: str, brightness_pct: int):
        _set_pct(name, brightness_pct)

    sa.set_screen = set_screen  # type: ignore[method-assign]
    sa.test_connectivity = test_connectivity  # type: ignore[method-assign]
    sa.manual_toggle = manual_toggle  # type: ignore[method-assign]
    sa.shutdown_all = shutdown_all  # type: ignore[method-assign]
    sa._probe_all = _probe_all  # type: ignore[method-assign]
    sa._apply = _apply  # type: ignore[method-assign]
    sa._demo_screens_installed = True
    sa._demo_state = demo_state
    logger.info(
        "🖥️ Demo screens ready: %s",
        ", ".join(screens.get(n, {}).get("friendly", n) for n in screens),
    )
