"""Stage current public sources and reused interop fixture; one bounded test only.

Run from repository root. No dependency installation or foreign directory writes.
"""
from pathlib import Path
import os
import shutil
import signal
import subprocess
import sys

root = Path.cwd().resolve()
fixture = root / 'bridge/fixtures/open-voice/native-handoff'
assert sys.argv[1:] in [[], ['--resume'], ['--real-stt'], ['--controller'], ['--controller', '--resume']]
controller = '--controller' in sys.argv[1:]
out = root / ('output/native-gate-d3b3d9549d18' if controller else 'output/native-handoff-3df39493694f')
real_stt = sys.argv[1:] == ['--real-stt']
resume = real_stt or '--resume' in sys.argv[1:]
out.mkdir(exist_ok=resume)
package = out / 'package'
shutil.copytree(fixture, package, dirs_exist_ok=resume)
tracked = subprocess.check_output(['git', 'ls-files', '-z'], text=True).split('\0')
for name in tracked:
    p = Path(name)
    if name.startswith('app/Sources/FloatingVoiceCore/') and p.suffix == '.swift':
        dest = package / 'native/Sources/FloatingVoiceCore' / p.name
    elif name == 'shared/presentation.json':
        dest = package / 'production' / p
    elif p.parent == Path('bridge') and (p.suffix == '.mjs' and not p.name.endswith('.test.mjs') or p.name in ['package.json', 'package-lock.json']):
        dest = package / 'production' / p
    else:
        continue
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / p, dest)
dependency = package / 'production/bridge/node_modules'
if not dependency.exists():
    os.symlink(root / 'bridge/node_modules', dependency, target_is_directory=True)
if controller:
    # Reuse existing test seams verbatim, not a third fixture or fake recognizer.
    shutil.copyfile(root / 'app/Tests/FloatingVoiceCoreTests/Fakes.swift',
                    package / 'Tests/ActualEngineInteropTests/Fakes.swift')
env = os.environ.copy()
env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
env.pop('FV_HANDOFF_REAL_STT', None) # Default can never inherit live mode.
if real_stt:
    # Explicit single-use mode only; never selected by health or fallback.
    env['FV_HANDOFF_REAL_STT'] = '1'
case = 'testCandidateReadyReplacesLegacyActivityBeforeCaptureOnset' if controller else 'testActualNativePacedPCMThroughProductionSpeech'
cmd = ['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift',
       'test', '--package-path', str(package), '--scratch-path', str(out / 'swift-build'),
       '--jobs', '1', '--filter', 'NativeSpeechHandoffTests.' + case]
logpath = out / ('focused-real-stt.log' if real_stt else 'focused-resume.log' if resume else 'focused.log')
with logpath.open('w') as log:
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    try:
        proc.wait(timeout=110)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
print(logpath.read_text()[-14000:])
sys.exit(proc.returncode)
