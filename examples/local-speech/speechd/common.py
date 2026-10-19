"""Shared helpers: structured logging and WAV framing."""
import json
import logging
import struct
import sys
import time


class JsonFormatter(logging.Formatter):
    def format(self, record):
        event = {"ts": round(record.created, 3), "level": record.levelname.lower(), "event": record.getMessage()}
        event.update(getattr(record, "fields", {}))
        if record.exc_info:
            event["exc"] = self.formatException(record.exc_info)
        return json.dumps(event, ensure_ascii=False)


def setup_logging(name: str, level: str = "info") -> logging.Logger:
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
    return logging.getLogger(name)


def log(logger: logging.Logger, event: str, level: int = logging.INFO, **fields):
    logger.log(level, event, extra={"fields": fields})


def wav_header(n_bytes: int, sample_rate: int, channels: int = 1, bits: int = 16) -> bytes:
    """A canonical 44-byte PCM WAV header for a body of n_bytes."""
    block = channels * bits // 8
    return (b"RIFF" + struct.pack("<I", 36 + n_bytes) + b"WAVE"
            + b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, sample_rate, sample_rate * block, block, bits)
            + b"data" + struct.pack("<I", n_bytes))


def now_ms() -> float:
    return time.perf_counter() * 1000.0
