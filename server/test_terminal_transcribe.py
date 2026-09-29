import base64
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error
import wave

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

import terminal_transcribe
from terminal_transcribe import (validate_audio, valid_language, seal, open_response,
                                 main, REQUEST_AAD, RESPONSE_AAD)


def wav(rate=16000, channels=1, width=2, seconds=1.0):
    out = io.BytesIO()
    with wave.open(out, 'wb') as clip:
        clip.setnchannels(channels)
        clip.setsampwidth(width)
        clip.setframerate(rate)
        clip.writeframes(b'\x00' * int(rate * seconds) * width * channels)
    return out.getvalue()


def run_main(stdin_bytes, **patches):
    output = io.StringIO()
    with patch('terminal_transcribe.sys.stdin', SimpleNamespace(buffer=io.BytesIO(stdin_bytes))), \
         patch('terminal_transcribe.sys.stdout', output):
        if patches:
            with patch.multiple('terminal_transcribe', **patches):
                main()
        else:
            main()
    return json.loads(output.getvalue()), output.getvalue()


class TranscribeTests(unittest.TestCase):
    def test_accepts_only_strict_16k_mono_pcm16(self):
        self.assertIsNotNone(validate_audio(base64.b64encode(wav()).decode()))
        for bad in [wav(rate=8000), wav(channels=2), wav(width=1), b'not a wav']:
            self.assertIsNone(validate_audio(base64.b64encode(bad).decode()))
        self.assertIsNone(validate_audio('***'))
        self.assertIsNone(validate_audio(''))
        self.assertIsNone(validate_audio(None))
        self.assertIsNone(validate_audio(base64.b64encode(wav(seconds=0)).decode()))

    def test_language_codes(self):
        self.assertTrue(valid_language('en'))
        self.assertFalse(valid_language('en-US; rm'))
        self.assertFalse(valid_language(''))

    def test_envelope_round_trips_with_the_server_layout(self):
        server = X25519PrivateKey.generate()
        server_public = base64.b64encode(server.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        audio = wav(seconds=0.1)
        token = b't' * 40
        envelope, response_key = seal(audio, 'en', token, server_public)
        self.assertEqual(envelope[:4], b'WN01')
        phone_public = X25519PublicKey.from_public_bytes(envelope[4:36])
        salt, nonce = envelope[36:52], envelope[52:64]
        shared = server.exchange(phone_public)

        def derive(info):
            return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(shared)

        clear = AESGCM(derive(REQUEST_AAD)).decrypt(nonce, envelope[64:], REQUEST_AAD)
        self.assertEqual(clear[:3], b'\x02en')
        self.assertEqual(int.from_bytes(clear[3:5], 'big'), len(token))
        self.assertEqual(clear[5:5 + len(token)], token)
        self.assertEqual(clear[5 + len(token) + 4:], audio)
        # Server seals the reply with the response key.
        reply_nonce = b'\x01' * 12
        sealed = b'WR01' + reply_nonce + AESGCM(derive(RESPONSE_AAD)).encrypt(
            reply_nonce, json.dumps({'text': ' hello there '}).encode(), RESPONSE_AAD)
        self.assertEqual(open_response(sealed, response_key), 'hello there')
        with self.assertRaises(Exception):
            open_response(b'XXXX' + sealed[4:], response_key)

    def test_invalid_input_never_contacts_the_server(self):
        called = []
        value, _ = run_main(json.dumps({'audio': 'nope'}).encode(),
                            transcribe=lambda *a: called.append(a))
        self.assertEqual(value, {'error': 'invalid'})
        self.assertEqual(called, [])

    def test_errors_map_to_codes_without_details(self):
        body = json.dumps({'audio': base64.b64encode(wav()).decode()}).encode()
        cases = [
            (urllib.error.HTTPError('u', 429, 'private detail', {}, None), 'busy'),
            (urllib.error.HTTPError('u', 401, 'private detail', {}, None), 'auth'),
            (TimeoutError('private detail'), 'timeout'),
            (urllib.error.URLError('private detail'), 'unreachable'),
            (RuntimeError('private detail'), 'unavailable'),
        ]
        for error, code in cases:
            def boom(*_args, error=error):
                raise error
            value, raw = run_main(body, transcribe=boom)
            self.assertEqual(value, {'error': code})
            self.assertNotIn('private detail', raw)

    def test_unreachable_home_reports_quickly(self):
        body = json.dumps({'audio': base64.b64encode(wav()).decode()}).encode()
        with patch('terminal_transcribe.urllib.request.urlopen', side_effect=OSError('down')):
            value, _ = run_main(body)
        self.assertEqual(value, {'error': 'unreachable'})

    def test_success_prints_only_text(self):
        body = json.dumps({'audio': base64.b64encode(wav()).decode()}).encode()
        value, _ = run_main(body, transcribe=lambda audio, lang: {'text': 'ship it'})
        self.assertEqual(value, {'text': 'ship it'})


if __name__ == '__main__':
    unittest.main()
