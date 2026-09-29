#!/usr/bin/env python3
"""Car dictation: forward one WAV to the home Whisper Notes /v1/transcribe.

Twin of terminal_review.py. The phone runs it over its existing SSH channel;
JSON arrives on stdin, never in process arguments:

    {"audio": "<base64 16 kHz mono 16-bit PCM WAV>", "language": "en"}

It prints exactly one JSON object: {"text": "..."} or {"error": "<code>"},
where code is one of invalid, unreachable, busy, auth, timeout, unavailable.
No audio, transcript, key or exception detail is logged or printed. Nothing
here starts, stops or reconfigures a service; it is a short-lived client.
"""
import base64
import io
import json
import os
from pathlib import Path
import struct
import sys
import urllib.error
import urllib.request
import wave

URL = 'http://127.0.0.1:8095'  # Trusted loopback; the phone hop is SSH.
MAX_STDIN = 12 * 1024 * 1024
MAX_SECONDS = 210  # the phone caps recordings at 180 s
HEALTH_TIMEOUT = 8  # "home unreachable within 8 s" -> phone fallback
TRANSCRIBE_TIMEOUT = 35  # stays inside the phone's 45 s SSH exec timeout
REQUEST_AAD = b'whisper-notes/request/v1'
RESPONSE_AAD = b'whisper-notes/response/v1'


def validate_audio(encoded):
    """Returns the WAV bytes when they are a strict 16 kHz mono PCM16 clip."""
    if not isinstance(encoded, str) or not encoded or len(encoded) > MAX_STDIN:
        return None
    try:
        audio = base64.b64decode(encoded, validate=True)
        with wave.open(io.BytesIO(audio), 'rb') as clip:
            shape = (clip.getnchannels(), clip.getsampwidth(), clip.getframerate())
            frames = clip.getnframes()
    except (ValueError, wave.Error, EOFError):
        return None
    if shape != (1, 2, 16000) or frames <= 0 or frames > MAX_SECONDS * 16000:
        return None
    return audio


def valid_language(value):
    return (isinstance(value, str) and 2 <= len(value) <= 3
            and value.isascii() and value.isalpha())


def seal(audio, language, token, server_public_b64):
    """Builds the WN01 envelope; returns (envelope, response_key)."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    server = X25519PublicKey.from_public_bytes(base64.b64decode(server_public_b64))
    key = X25519PrivateKey.generate()
    shared = key.exchange(server)
    salt, nonce = os.urandom(16), os.urandom(12)

    def derive(info):
        return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(shared)

    lang = language.encode()
    clear = (bytes([len(lang)]) + lang + struct.pack('>H', len(token)) + token
             + struct.pack('>I', len(audio)) + audio)
    envelope = (b'WN01' + key.public_key().public_bytes(serialization.Encoding.Raw,
                serialization.PublicFormat.Raw) + salt + nonce
                + AESGCM(derive(REQUEST_AAD)).encrypt(nonce, clear, REQUEST_AAD))
    return envelope, derive(RESPONSE_AAD)


def open_response(body, response_key):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if len(body) < 32 or body[:4] != b'WR01':
        raise ValueError('not an encrypted response')
    clear = AESGCM(response_key).decrypt(body[4:16], body[16:], RESPONSE_AAD)
    value = json.loads(clear)
    text = value.get('text') if isinstance(value, dict) else None
    if not isinstance(text, str):
        raise ValueError('no text')
    return text.strip()


def transcribe(audio, language):
    try:
        with urllib.request.urlopen(URL + '/health', timeout=HEALTH_TIMEOUT) as response:
            health = json.load(response)
    except (OSError, ValueError):
        return {'error': 'unreachable'}
    token_path = Path(os.environ.get('DEVOTA_REVIEW_TOKEN_FILE',
        str(Path.home() / 'whisper-notes/.secrets/api-token')))
    try:
        token = token_path.read_text().strip().encode()
    except OSError:
        return {'error': 'auth'}
    if not 32 <= len(token) <= 4096:
        return {'error': 'auth'}
    envelope, response_key = seal(audio, language, token, health['public_key'])
    request = urllib.request.Request(URL + '/v1/transcribe', data=envelope, headers={
        'Content-Type': 'application/vnd.whisper-notes.encrypted',
        'Accept': 'application/vnd.whisper-notes.encrypted'}, method='POST')
    with urllib.request.urlopen(request, timeout=TRANSCRIBE_TIMEOUT) as response:
        body = response.read(1024 * 1024 + 1)
    if len(body) > 1024 * 1024:
        return {'error': 'invalid'}
    return {'text': open_response(body, response_key)}


def main():
    try:
        request = json.loads(sys.stdin.buffer.read(MAX_STDIN + 1))
        audio = validate_audio(request.get('audio')) if isinstance(request, dict) else None
        language = request.get('language', 'en') if isinstance(request, dict) else ''
        if audio is None or not valid_language(language):
            result = {'error': 'invalid'}
        else:
            result = transcribe(audio, language.lower())
    except urllib.error.HTTPError as error:
        result = {'error': {429: 'busy', 401: 'auth', 400: 'invalid',
                            413: 'invalid'}.get(error.code, 'unavailable')}
    except TimeoutError:
        result = {'error': 'timeout'}
    except urllib.error.URLError:
        result = {'error': 'unreachable'}
    except Exception:
        result = {'error': 'unavailable'}
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
