"""Stdlib, in-memory fixtures. No server/model imports, sockets or subprocesses."""
import ast
import asyncio
from contextlib import aclosing, asynccontextmanager
import hashlib
import hmac
import itertools
import json
import logging
import math
import os
from pathlib import Path
import runpy
import struct
import time
from types import SimpleNamespace as NS
import unittest

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


class NoSocketLoop(asyncio.SelectorEventLoop):
    def _make_self_pipe(self):
        self._ssock = self._csock = None

    def _close_self_pipe(self):
        pass

    def _write_to_self(self):
        pass


class Policy(asyncio.DefaultEventLoopPolicy):
    def new_event_loop(self):
        return NoSocketLoop()


def definitions(file, names, ns):
    tree = ast.parse((ROOT / file).read_text())
    nodes = [n for n in tree.body if isinstance(n, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef))
             and n.name in names]
    assert {n.name for n in nodes} == set(names)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), file, 'exec'), ns)
    return ns


class Response:
    def __init__(self, *, body=None, status=200, **kwargs):
        self.status, self.body = status, body
        self.prepared = False
        self.eof = False

    async def prepare(self, request):
        self.prepared = True
        self.body = b''

    async def write(self, data):
        self.body += data

    async def write_eof(self):
        self.eof = True


def json_response(body, status=200):
    return Response(body=json.dumps(body).encode(), status=status)


def gateway_ns():
    ns = dict(asyncio=asyncio, math=math, os=os, time=time, Path=Path, json=json,
              hmac=hmac, hashlib=hashlib, aclosing=aclosing, asynccontextmanager=asynccontextmanager,
              logging=logging, logger=logging.getLogger('fixture'), log=lambda *a, **k: None,
              now_ms=lambda: time.monotonic()*1000, SAMPLE_RATE=24000, MAX_INPUT=10000,
              REQUEST_IDS=itertools.count(1), VOICE_DEFAULTS={'seed':42,'cfg_scale':1,'instruction':None},
              aiohttp=NS(ClientError=OSError, ClientConnectionResetError=ConnectionResetError),
              web=NS(json_response=json_response, Response=Response, StreamResponse=Response))
    ns.update(runpy.run_path(str(ROOT / 'speechd/common.py')))
    return definitions('speechd/tts_gateway.py',
                       ['Busy','Overloaded','UpstreamError','Gateway','_error','speech','model_control'], ns)


class SourceContracts(unittest.TestCase):
    def test_python_syntax(self):
        for path in ROOT.rglob('*.py'):
            ast.parse(path.read_text(), filename=str(path.relative_to(ROOT)))

    def test_wav_header(self):
        ns = runpy.run_path(str(ROOT / 'speechd/common.py'))
        for size in (0, 2, 48000):
            header = ns['wav_header'](size, 24000)
            self.assertEqual(len(header), 44)
            self.assertEqual(header[:4], b'RIFF')
            self.assertEqual(struct.unpack('<I', header[4:8])[0], size+36)
            self.assertEqual(struct.unpack('<I', header[40:])[0], size)
            self.assertEqual(struct.unpack('<HHI', header[20:28]), (1, 1, 24000))

    def test_asr_auth(self):
        auth = definitions('speechd/stt_server.py', ['_authorized'], {'hmac':hmac})['_authorized']
        self.assertTrue(auth(NS(headers={}), ''))
        self.assertFalse(auth(NS(headers={}), 'fixture-key'))
        self.assertFalse(auth(NS(headers={'Authorization':'Bearer wrong'}), 'fixture-key'))
        self.assertTrue(auth(NS(headers={'Authorization':'Bearer fixture-key'}), 'fixture-key'))

    def test_cli_and_readme_flags(self):
        for module in ('stt_server', 'tts_gateway'):
            tree = ast.parse((ROOT / f'speechd/{module}.py').read_text())
            options = {n.args[0].value: n for n in ast.walk(tree)
                       if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                       and n.func.attr == 'add_argument' and n.args and isinstance(n.args[0], ast.Constant)}
            host = options['--host']
            self.assertEqual(next(k.value.value for k in host.keywords if k.arg == 'default'), '127.0.0.1')
            expected = ['--backend','--model','--precision','--model-id','--revision','--no-partials'] if module == 'stt_server' else ['--upstream','--voices','--state','--default-voice']
            self.assertTrue(set(expected + ['--host','--port']) <= options.keys())
            if module == 'tts_gateway':
                self.assertTrue(next(k.value.value for k in options['--default-voice'].keywords if k.arg == 'required'))

    def test_current_client_contracts(self):
        for platform in ('macos', 'ios'):
            base = REPO / platform / 'app/Sources/FloatingVoiceCore'
            turn = (base / 'TurnTaking.swift').read_text()
            speech = (base / 'Speech.swift').read_text()
            for field in ('input_audio.end', 'transcript.partial', 'partials', 'transcript'):
                self.assertIn(field, turn)
            for field in ('response_format', 'pcm', 'wav', 'voice', 'input'):
                self.assertIn(field, speech)
        stt = (ROOT / 'speechd/stt_server.py').read_text()
        tts = (ROOT / 'speechd/tts_gateway.py').read_text()
        self.assertIn('"/v1/transcribe", transcribe', stt)
        self.assertIn('"/v1/audio/speech", speech', tts)
        for token in ('code=1000', 'code=1003', 'code=1009', 'input_audio.end', 'transcript.partial'):
            self.assertIn(token, stt)
        self.assertNotIn('body.get("model"', tts)
        bridge = (REPO / 'ios/bridge/server.mjs').read_text()
        self.assertIn("'/asr/v1/transcribe?partials=1'", bridge)
        self.assertIn("'/tts/v1/audio/speech'", bridge)


class ASRFixtures(unittest.IsolatedAsyncioTestCase):
    async def test_buffered_final_and_cancel(self):
        ns = definitions('speechd/stt_server.py', ['BufferedUtterance'],
                         dict(asyncio=asyncio, now_ms=lambda: 0,
                              np=NS(concatenate=lambda chunks: sum(chunks, []), zeros=lambda *a: [], float32=None)))
        async def run(fn, *args):
            return fn(*args)
        emitted = []
        async def emit(text):
            emitted.append(text)
        for cancelled in (False, True):
            utterance = ns['BufferedUtterance'](NS(run=run), NS(transcribe=lambda pcm: 'fixture final'))
            utterance.feed([0, 1])
            utterance.cancel() if cancelled else utterance.end()
            self.assertEqual(await utterance.run(emit, {'gpu_ms':0}), not cancelled)
        self.assertEqual(emitted, ['fixture final'])

    async def test_voxtral_committed_deltas(self):
        ns = definitions('speechd/stt_server.py', ['VoxtralUtterance'],
                         dict(asyncio=asyncio, now_ms=lambda: 0))
        session = NS(generated=[], _prev_text='', done=False)
        def step(**kwargs):
            session.generated.append(1)
            session._prev_text = 'Hello' if len(session.generated) == 1 else 'Hello world'
            session.done = len(session.generated) == 2
        session.step = step
        async def run(fn, *args):
            return fn(*args)
        utterance = ns['VoxtralUtterance'](NS(run=run), NS(args=NS(step_tokens=16)))
        utterance.sess = session
        utterance.wake.set()
        emitted = []
        async def emit(text):
            emitted.append(text)
        self.assertTrue(await utterance.run(emit, {'gpu_ms':0}))
        self.assertEqual(emitted, ['Hello', ' world'])


class GatewayFixtures(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.ns = gateway_ns()
        self.gw = self.ns['Gateway'](NS(default_voice='reference', max_queued=2, queue_wait_s=.02,
                                      api_key='', upstream='http://fixture.invalid'))
        self.gw.state = 'ready'
        self.gw.voices = {'reference': {'seed':42, 'cfg_scale':1,'instruction':None}}

    def request(self, body):
        async def get_json():
            return body
        return NS(app={'gateway':self.gw}, headers={}, json=get_json)

    async def test_validation_and_voice_resolution(self):
        for body in ([], {}, {'input':' '}, {'input':'x'*10001}, {'input':'hi','voice':'missing'},
                     {'input':'hi','response_format':'mp3'}, {'input':'hi','stream_format':'sse'}):
            self.assertEqual((await self.ns['speech'](self.request(body))).status, 400)
        self.assertEqual(self.gw.resolve('default'), 'reference')
        self.assertEqual(self.gw.resolve(None), 'reference')
        self.assertIsNone(self.gw.resolve('unregistered'))

    async def test_auth_and_readiness(self):
        self.gw.state = 'starting'
        self.gw.args.api_key = 'fixture-key'
        self.assertEqual((await self.ns['speech'](self.request({'input':'hi'}))).status, 401)
        self.gw.args.api_key = ''
        self.assertEqual((await self.ns['speech'](self.request({'input':'hi'}))).status, 503)

    async def test_complete_wav_and_streamed_pcm(self):
        async def synth(*args):
            yield b'\x01\x00'
            yield b'\x02\x00'
        self.gw.synthesize = synth
        wav = await self.ns['speech'](self.request({'input':'hi'}))
        self.assertEqual(wav.body[-4:], b'\x01\x00\x02\x00')
        self.assertEqual(struct.unpack('<I', wav.body[40:44])[0], 4)
        pcm = await self.ns['speech'](self.request({'input':'hi','response_format':'pcm'}))
        self.assertEqual(pcm.body, b'\x01\x00\x02\x00')
        self.assertTrue(pcm.eof)

    async def test_queue_full_and_timeout(self):
        await self.gw.lock.acquire()
        self.gw.max_queued = 0
        response = await self.ns['speech'](self.request({'input':'hi'}))
        self.assertEqual(response.status, 429)
        self.assertEqual(json.loads(response.body)['error']['code'], 'queue_full')
        self.gw.max_queued = 1
        response = await self.ns['speech'](self.request({'input':'hi'}))
        self.assertEqual(response.status, 429)
        self.assertEqual(json.loads(response.body)['error']['code'], 'queue_timeout')
        self.assertEqual(self.gw.queued, 0)
        self.gw.lock.release()

    async def test_fifo_and_cancelled_waiter(self):
        await self.gw.lock.acquire()
        order = []
        async def waiter(index):
            async with self.gw.synthesis_slot():
                order.append(index)
        one, two = [asyncio.create_task(waiter(i)) for i in (1,2)]
        await asyncio.sleep(0)
        self.assertEqual(self.gw.queued, 2)
        two.cancel()
        await asyncio.gather(two, return_exceptions=True)
        self.gw.lock.release()
        await one
        self.assertEqual(order, [1])
        self.assertFalse(self.gw.lock.locked())

    async def test_cancel_closes_mock_upstream(self):
        blocked = asyncio.Event()
        async def chunks():
            yield b'\0\0'
            blocked.set()
            await asyncio.Event().wait()
        response = NS(status=200, content=NS(iter_any=chunks, is_eof=lambda: True), closed=False)
        response.close = lambda: setattr(response,'closed',True)
        async def post(*args, **kwargs):
            return response
        self.gw.http = NS(post=post)
        async def consume():
            async with aclosing(self.gw.synthesize('reference','hello',None)) as stream:
                async for _ in stream:
                    pass
        task = asyncio.create_task(consume())
        await asyncio.wait_for(blocked.wait(), .5)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        self.assertTrue(response.closed)
        self.assertFalse(self.gw.lock.locked())

    async def test_admin_guards_without_forwarding(self):
        for remote, key, expected in [('192.0.2.1','',403), ('127.0.0.1','fixture-key',401)]:
            self.gw.args.api_key = key
            request = NS(app={'gateway':self.gw}, remote=remote, headers={}, match_info={'action':'unload'})
            self.assertEqual((await self.ns['model_control'](request)).status, expected)
        self.gw.args.api_key = ''
        await self.gw.lock.acquire()
        self.assertEqual((await self.ns['model_control'](request)).status, 409)
        self.gw.lock.release()


if __name__ == '__main__':
    asyncio.set_event_loop_policy(Policy())
    unittest.main()
